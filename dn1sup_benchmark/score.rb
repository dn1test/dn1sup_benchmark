# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/score.rb — необязательный общий балл в стиле Geekbench.
#
# Формула (ТЗ §3.10, §12: балл необязателен, веса и база опубликованы):
#   балл теста   = base/value для «ms» (меньше — лучше) или value/base для
#                  «fps» (больше — лучше); у базовой машины каждый балл = 1.0;
#   балл категории = геометрическое среднее баллов её тестов;
#   общий балл   = 1000 × взвешенное геометрическое среднее категорий
#                  (веса ниже; веса доступных категорий перенормируются).
# Итог: 1000 ≈ конфигурация из baseline-файла. Шкала условная, привязана
# к профилю и набору тестов; это НЕ рейтинг SketchUp и НЕ сравнение между
# разными профилями.
#
# Балл вычисляется только для профилей, у которых есть baseline-файл
# (baseline-<profile>-v1.json рядом с кодом). Пропущенные/упавшие тесты
# дают статус partial с перечнем недостающих (не подменяются нулями).
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Score
    SCORE_VERSION = '1'

    # Опубликованные веса категорий (сумма = 1). API и графика доминируют
    # в интерактивной работе SketchUp, файлы — самый шумный компонент.
    WEIGHTS = {
      'ruby' => 0.20,
      'api' => 0.40,
      'documents' => 0.10,
      'graphics' => 0.30
    }.freeze

    # Тесты, входящие в балл (канонический набор ТЗ; scene_gen_* и легаси-
    # дубли не участвуют, чтобы не учитывать одну работу дважды).
    INCLUDED = {
      'ruby' => %w[RUBY-01],
      'api' => %w[API-01 API-02 API-03 API-04 API-05 API-06],
      'documents' => %w[DOC-01 DOC-02],
      'graphics' => %w[fps_components_static fps_grid_static fps_grid_orbit
                       fps_grid_pan fps_grid_zoom fps_textured_static]
    }.freeze

    class << self
      # Возвращает хеш балла или nil (если балл неприменим к прогону).
      def compute(run_data)
        return nil if run_data.nil?

        profile = run_data.dig('meta', 'profile')
        baseline = load_baseline(profile)
        if baseline.nil?
          return { 'score_version' => SCORE_VERSION, 'profile' => profile,
                   'status' => 'unavailable', 'overall' => nil,
                   'reason' => "нет базовых значений для профиля «#{profile}» " \
                               '(балл публикуется только для профилей с baseline-файлом)' }
        end

        by_id = {}
        (run_data['results'] || []).each { |r| by_id[r['id']] = r }

        categories = {}
        missing = []
        WEIGHTS.keys.each do |cat|
          tests = {}
          INCLUDED.fetch(cat, []).each do |tid|
            base = baseline.dig('values', tid)
            rec = by_id[tid]
            score = test_score(base, rec)
            if score
              tests[tid] = { 'score' => score.round(1), 'value' => rec['value'],
                             'unit' => rec['unit'], 'base' => base && base['value'] }
            else
              missing << tid
            end
          end
          categories[cat] = { 'score' => geomean(tests.values.map { |t| t['score'] }),
                              'tests' => tests } unless tests.empty?
        end

        available = categories.select { |cat, c| c['score'] }
        # Шкала: 1000 = конфигурация из baseline-файла.
        overall = weighted_geomean(available.map { |cat, c| [c['score'], WEIGHTS[cat]] })
        overall &&= overall * 1000.0
        statuses = available.values.map { |c| c['score'] }
        {
          'score_version' => SCORE_VERSION,
          'profile' => profile,
          'baseline' => baseline.dig('reference', 'source_run'),
          'weights' => WEIGHTS,
          'categories' => categories.transform_values { |c| c['score']&.round(1) },
          'category_tests' => categories.transform_values { |c| c['tests'] },
          'missing' => missing,
          'status' => missing.empty? && available.size == WEIGHTS.size ? 'complete' : 'partial',
          'overall' => overall&.round(1)
        }
      rescue StandardError => e
        { 'score_version' => SCORE_VERSION, 'status' => 'unavailable', 'overall' => nil,
          'reason' => "#{e.class}: #{e.message}" }
      end

      private

      def test_score(base, rec)
        return nil if base.nil? || rec.nil?
        return nil if rec['status'] != 'passed'

        value = rec['value']
        base_v = base['value']
        return nil if value.nil? || base_v.nil? || value <= 0 || base_v <= 0

        if rec['unit'] == base['unit']
          rec['unit'] == 'fps' ? value / base_v : base_v / value
        end
      end

      def geomean(values)
        vals = values.compact.reject { |v| v <= 0 }
        return nil if vals.empty?

        Math.exp(vals.map { |v| Math.log(v) }.sum / vals.size)
      end

      def weighted_geomean(pairs)
        pairs = pairs.select { |v, w| v && w && v.positive? && w.positive? }
        return nil if pairs.empty?

        total_w = pairs.sum { |_, w| w }
        Math.exp(pairs.sum { |v, w| w * Math.log(v) } / total_w)
      end

      def load_baseline(profile)
        path = File.join(Dn1supBenchmark::PLUG_ROOT, "baseline-#{profile}-v1.json")
        return nil unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
    end
  end
end
