# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/report.rb — сохранение результатов и HTML-отчёты.
#
# Файлы кладутся в ~/Documents/SketchUp Benchmarks/:
#   bench-SU<версия>__<профиль>_<дата>.json — сырые данные прогона;
#   bench-SU<версия>__<профиль>_<дата>.html — одиночный отчёт;
#   compare-<дата>.html — сравнение нескольких прогонов (Report.compare).
# HTML самодостаточный: inline CSS + SVG-бары, без CDN/интернета.
#
# Сравнение (ТЗ §12): проценты считаются ТОЛЬКО для пар тестов с одинаковыми
# test_version, единицами и параметрами нагрузки; остальные помечаются
# несовместимыми с указанием причины — не объединяются в общий рейтинг.
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Report
    COLORS = {
      'ruby' => '#5e81ac', 'api' => '#a3be8c', 'documents' => '#d08770',
      'graphics' => '#b48ead',
      # легаси-группы отчётов 0.1.0
      'scene_gen' => '#5e81ac', 'viewport' => '#a3be8c', 'hierarchy' => '#ebcb8b',
      'editing' => '#d08770', 'textures' => '#b48ead'
    }.freeze

    STATUS_LABELS = {
      'passed' => '', 'failed' => '(ошибка)', 'cancelled' => '(отменено)',
      'skipped' => '(пропущено)'
    }.freeze

    class << self
      def report_dir
        docs = File.join(ENV['USERPROFILE'] || ENV['HOME'] || Dir.tmpdir, 'Documents')
        dir = File.join(docs, 'SketchUp Benchmarks')
        PngGen.mkdir_p(dir)
        dir
      end

      def save_run(data)
        dir = report_dir
        su = data['meta']['sketchup_version'].to_s.split('.').first
        tag = "SU#{su}__#{data['meta']['profile']}__#{Time.now.strftime('%Y%m%d-%H%M%S')}"
        json_path = File.join(dir, "bench-#{tag}.json")
        html_path = File.join(dir, "bench-#{tag}.html")
        File.write(json_path, JSON.pretty_generate(data))
        File.write(html_path, html_single(data))
        { 'json' => json_path, 'html' => html_path }
      end

      # Сравнение прогонов: runs — массив data-хешей (или путей к JSON).
      # Базовый — первый; у совместимых колонок — % к базе.
      def compare(runs, out_path = nil)
        datas = runs.map { |r| r.is_a?(String) ? JSON.parse(File.read(r)) : r }
        raise 'нужно минимум 2 прогона' if datas.size < 2

        out_path ||= File.join(report_dir, "compare-#{Time.now.strftime('%Y%m%d-%H%M%S')}.html")
        File.write(out_path, html_compare(datas))
        { 'html' => out_path, 'runs' => datas.size }
      end

      # Данные сравнения для UI (те же правила совместимости, что и в HTML).
      def compare_data(datas)
        raise 'нужно минимум 2 прогона' if datas.size < 2

        warnings = []
        scores = datas.map { |d| d['score'] || Score.compute(d) }
        score_cells = scores.each_with_index.map do |s, i|
          next { 'overall' => nil, 'reason' => s.nil? ? 'нет балла' : s['reason'] } if s.nil? || s['overall'].nil?

          cell = { 'overall' => s['overall'], 'status' => s['status'], 'missing' => s['missing'] }
          if i.positive?
            reason = score_compatibility(scores.first, s)
            base_s = scores.first['overall']
            if reason
              cell['incompatible'] = reason
            elsif base_s && base_s.positive?
              cell['percent'] = ((s['overall'] / base_s - 1) * 100).round(1)
            end
          end
          cell
        end
        cols = datas.map do |d|
          { 'sketchup' => d.dig('meta', 'sketchup_version'),
            'profile' => d.dig('meta', 'profile'),
            'suite' => d.dig('meta', 'test_suite_version') }
        end
        ids = []
        datas.each do |d|
          (d['results'] || []).each { |r| ids << r['id'] unless ids.include?(r['id']) }
        end
        by_run_test = datas.map do |d|
          h = {}
          (d['results'] || []).each { |r| h[r['id']] = r }
          h
        end

        rows = ids.map do |tid|
          base_r = by_run_test.first[tid]
          name = base_r ? (base_r['name'] || tid) : tid
          cells = datas.each_with_index.map do |_d, i|
            r = by_run_test[i][tid]
            next { 'value' => nil } if r.nil? || r['value'].nil?

            cell = { 'value' => r['value'], 'status' => r['status'] }
            next cell if i.zero?

            reason = base_r.nil? ? 'нет в базовом прогоне' : incompatibility_reason(base_r, r)
            basev = base_r && base_r['value']
            if reason
              cell['incompatible'] = reason
              warnings << "#{name}: #{cols[i]['sketchup']} #{cols[i]['profile']} — #{reason}"
            elsif basev && basev.positive?
              rel = (r['value'] / basev - 1) * 100
              cell['percent'] = rel.round(1)
            end
            cell
          end
          { 'id' => tid, 'name' => name,
            'group' => base_r ? base_r['group'] : 'api',
            'unit' => base_r ? base_r['unit'] : nil,
            'higher' => base_r ? base_r['higher_is_better'] : false,
            'cells' => cells }
        end

        { 'columns' => cols, 'rows' => rows, 'warnings' => warnings.uniq,
          'base_index' => 0, 'scores' => score_cells }
      end

      # Список сохранённых прогонов (новые сверху) — для вкладки «Сравнение».
      def list_runs(limit = 30)
        # Backslash в glob-паттерне — экранирование: приводим к «/».
        pattern = File.join(report_dir, 'bench-*.json').tr('\\', '/')
        files = Dir.glob(pattern)
                   .sort_by { |f| File.mtime(f) }.reverse.first(limit)
        files.map do |f|
          data = JSON.parse(File.read(f)) rescue next
          meta = data['meta'] || {}
          { 'path' => f, 'file' => File.basename(f),
            'sketchup' => meta['sketchup_version'], 'profile' => meta['profile'],
            'suite' => meta['test_suite_version'], 'started_at' => meta['started_at'],
            'tests' => (data['results'] || []).size }
        end.compact
      end

      # ---------------------------------------------------------------- single

      def html_single(data)
        meta = data['meta']
        results = data['results'] || []
        groups = results.group_by { |r| r['group'] }
        b = +"<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
        b << "<title>Бенчмарк SketchUp — SU#{meta['sketchup_version']} / #{meta['profile']}</title>\n"
        b << css
        b << "</head>\n<body>\n"
        b << "<h1>Бенчмарк производительности SketchUp</h1>\n"
        b << meta_table(meta)
        b << score_section(data['score']) if data['score']
        groups.keys.each do |g|
          b << group_section(g, groups[g])
        end
        errs = results.select { |r| r['status'] != 'passed' }
        unless errs.empty?
          b << "<h2>Не пройдено / пропущено</h2>\n<ul>\n"
          errs.each do |r|
            b << "<li><code>#{esc(r['id'])}</code> #{esc(STATUS_LABELS.fetch(r['status'], r['status']))}: " \
                 "#{esc(r['error'])}</li>\n"
          end
          b << "</ul>\n"
        end
        b << "<p class=\"muted\">Сгенерировано dn1sup_benchmark v#{meta['extension_version']} " \
             "(набор тестов v#{meta['test_suite_version']}). Меньше мс — лучше; больше FPS — лучше. " \
             "FPS — счётчик кадров Ruby-стороны, не GPU-счётчик.</p>\n</body>\n</html>\n"
        b
      end

      def meta_table(meta)
        env = meta['environment'] || {}
        run = meta['run'] || {}
        rows = [
          ['SketchUp', "SU #{meta['sketchup_version']} (#{meta['version_number']})"],
          ['Ruby', meta['ruby_version']],
          ['ОС / платформа', "#{meta['os']} / #{meta['platform']}"],
          ['Профиль', meta['profile'].to_s + (run['status'] ? " — #{run['status']}" : '')],
          ['Набор тестов', "v#{meta['test_suite_version']} (схема отчёта v#{meta['schema_version']})"],
          ['Начало прогона', meta['started_at']],
          ['CPU', "#{meta['cpu']} × #{meta['cores']} ядер"],
          ['Масштаб DPI', env['ui_scale_factor']],
          ['Вьюпорт', env['viewport'] ? "#{env['viewport']['width']}×#{env['viewport']['height']}" : nil],
          ['Загружено расширений', meta['extensions_loaded']]
        ]
        out = +"<table class=\"meta\">\n"
        rows.each do |k, v|
          next if v.nil?

          out << "<tr><th>#{esc(k)}</th><td>#{esc(v)}</td></tr>\n"
        end
        out << "</table>\n"
        out
      end

      # Секция необязательного общего балла (Geekbench-стиль): формула и веса
      # опубликованы, раздельные оценки остаются основным содержанием отчёта.
      def score_section(score)
        out = +"<h2>Общий балл</h2>\n"
        out << "<table class=\"meta\">\n"
        overall = score['overall']
        status = score['status']
        out << "<tr><th>Балл (#{esc(score['profile'])})</th><td>"
        if overall
          out << "<b style=\"font-size: 20px\">#{overall.round(0)}</b> " \
                 "<span class=\"muted\">(#{status}; 1000 = базовый прогон #{esc(score['baseline'])})</span>"
        else
          out << "<span class=\"muted\">недоступен — #{esc(score['reason'])}</span>"
        end
        out << '</td></tr>'
        (score['categories'] || {}).each do |cat, val|
          w = (score['weights'] || {})[cat]
          out << "<tr><th>#{esc(Runner::GROUP_TITLES.fetch(cat, cat))} " \
                 "<span class=\"muted\">×#{w}</span></th><td>#{val ? val.round(0) : '—'}</td></tr>\n"
        end
        out << "</table>\n"
        unless (score['missing'] || []).empty?
          out << "<p class=\"muted\">Не учтены (partial): #{esc(score['missing'].join(', '))}</p>\n"
        end
        out << "<p class=\"muted\">Формула: балл теста = base/value (мс) или value/base (fps) " \
               "к базовому прогону; категория — геометрическое среднее; общий — взвешенное " \
               "геометрическое среднее категорий × 1000. Необязательная сводная оценка, " \
               "НЕ официальный рейтинг SketchUp; сравним только между одинаковыми профилями. " \
               "FPS-часть зависит от частоты обновления дисплея.</p>\n"
        out
      end

      # Сравнимы ли общие баллы пары прогонов (одинаковые профиль и набор).
      def score_compatibility(a, b)
        return 'нет балла' if a.nil? || b.nil? || a['overall'].nil? || b['overall'].nil?
        return 'профиль различается' if a['profile'] != b['profile']

        nil
      end

      def html_compare_scores(datas)
        scores = datas.map { |d| d['score'] || Score.compute(d) }
        cols = datas.map { |d| "SU#{d['meta']['sketchup_version']} #{d['meta']['profile']}" }
        out = +"<h2>Общие баллы</h2>\n<table class=\"bench compare\">\n<tr><th>Балл</th>"
        cols.each { |c| out << "<th class=\"num\">#{esc(c)}</th>" }
        out << "</tr>\n<tr><td>Общий балл (1000 = базовый прогон)</td>"
        scores.each_with_index do |s, i|
          if s.nil? || s['overall'].nil?
            reason = s && s['reason'] ? " (#{esc(s['reason'])})" : ''
            out << "<td class=\"num muted\">—#{reason}</td>"
            next
          end
          cell = "<b>#{s['overall'].round(0)}</b>"
          if i.positive?
            reason = score_compatibility(scores.first, s)
            base_s = scores.first && scores.first['overall']
            if reason
              cell << " <span class=\"muted\">#{esc(reason)}</span>"
            elsif base_s && base_s.positive?
              rel = (s['overall'] / base_s - 1) * 100
              cls = rel.abs < 3 ? 'same' : (rel.positive? ? 'better' : 'worse')
              cell << " <span class=\"#{cls}\">#{rel >= 0 ? '+' : ''}#{rel.round(1)}%</span>"
            end
          end
          out << "<td class=\"num#{i.zero? ? ' base' : ''}\">#{cell}</td>"
        end
        out << "</tr>\n</table>\n"
        out
      end

      def group_section(group, results)
        title = Runner::GROUP_TITLES.fetch(group, group)
        color = COLORS.fetch(group, '#888888')
        out = +"<h2>#{esc(title)}</h2>\n<table class=\"bench\">\n"
        out << "<tr><th>Тест</th><th>Статус</th><th class=\"num\">Значение</th><th class=\"num\">min</th>" \
               "<th class=\"num\">max</th><th class=\"num\">p95</th><th class=\"num\">Повт.</th>" \
               "<th class=\"num\">оп/с</th><th>Диаграмма</th><th class=\"num\">Сущностей</th></tr>\n"
        max = results.map { |r| r['value'].to_f }.compact.max
        max = 0.0 if max.nil? || max <= 0
        results.each do |r|
          val = r['value']
          out << "<tr#{r['status'] != 'passed' ? " class=\"err\"" : ''}>"
          out << "<td>#{esc(r['name'] || r['id'])}</td>"
          out << "<td>#{esc(STATUS_LABELS.fetch(r['status'], r['status'].to_s))}</td>"
          if val
            out << "<td class=\"num\"><b>#{fmt(val, r['unit'])}</b></td>"
            out << "<td class=\"num\">#{fmt(r['min_ms'] || r['min'], r['unit'])}</td>"
            out << "<td class=\"num\">#{fmt(r['max_ms'] || r['max'], r['unit'])}</td>"
            out << "<td class=\"num\">#{fmt(r['p95_ms'] || r['p95'], r['unit'])}</td>"
            out << "<td class=\"num\">#{r['repeat_count'] || (r['times_ms'] || []).size}</td>"
            out << "<td class=\"num\">#{r['ops_per_sec'] || '—'}</td>"
            out << "<td>#{bar(val, max, color, r['unit'] == 'fps' || r['higher_is_better'])}</td>"
          else
            out << '<td class="num muted">—</td><td class="num muted">—</td>' \
                   '<td class="num muted">—</td><td class="num muted">—</td>' \
                   '<td class="num muted">—</td><td class="num muted">—</td>' \
                   '<td class="muted">—</td>'
          end
          out << "<td class=\"num\">#{r['entities']}</td></tr>\n"
        end
        out << "</table>\n"
        out
      end

      def bar(value, max, color, higher)
        return '' if max <= 0

        frac = higher ? value / max : (max - value) / max # «зелёнее» — ближе к лучшему
        frac = 0.0 if frac < 0
        w = (frac * 180).round
        "<svg width=\"200\" height=\"14\" xmlns=\"http://www.w3.org/2000/svg\">" \
          "<rect x=\"0\" y=\"3\" width=\"180\" height=\"8\" fill=\"#e5e5e5\" rx=\"2\"/>" \
          "<rect x=\"0\" y=\"3\" width=\"#{w}\" height=\"8\" fill=\"#{color}\" rx=\"2\"/>" \
          "</svg>"
      end

      # --------------------------------------------------------------- compare

      # Причина несовместимости пары записей или nil, если сравнивать можно.
      def incompatibility_reason(base_r, other_r)
        return 'в отчёте нет версии теста (запись старого формата)' if base_r['test_version'].nil? || other_r['test_version'].nil?
        return "версия теста: #{base_r['test_version']} vs #{other_r['test_version']}" if base_r['test_version'] != other_r['test_version']
        return "единицы: #{base_r['unit']} vs #{other_r['unit']}" if base_r['unit'] != other_r['unit']

        base_p = sort_deep(base_r['parameters'] || {})
        other_p = sort_deep(other_r['parameters'] || {})
        return 'параметры нагрузки различаются' if base_p != other_p

        nil
      end

      def sort_deep(obj)
        case obj
        when Hash then obj.keys.sort.map { |k| [k, sort_deep(obj[k])] }.to_h
        when Array then obj.map { |v| sort_deep(v) }
        else obj
        end
      end

      def html_compare(datas)
        base = datas.first
        cols = datas.map { |d| "SU#{d['meta']['sketchup_version']} #{d['meta']['profile']}" }
        ids = []
        datas.each do |d|
          (d['results'] || []).each { |r| ids << r['id'] unless ids.include?(r['id']) }
        end
        by_run_test = datas.map do |d|
          h = {}
          (d['results'] || []).each { |r| h[r['id']] = r }
          h
        end

        b = +"<html lang=\"ru\">\n<head>\n<meta charset=\"utf-8\">\n"
        b << "<title>Сравнение прогонов SketchUp</title>\n" << css << "</head>\n<body>\n"
        b << "<h1>Сравнение прогонов SketchUp</h1>\n"
        b << "<p class=\"muted\">База — #{esc(cols.first)}. Зелёным — лучше базы, " \
             "красным — хуже (порог ±3%). Проценты считаются только для совместимых пар " \
             "(одинаковые версия теста, единицы и параметры нагрузки); " \
             "меньше мс — лучше, больше FPS — лучше.</p>\n"
        b << meta_table(base['meta'])
        b << html_compare_scores(datas)

        warnings = []
        groups = {}
        ids.each do |tid|
          first = by_run_test.map { |h| h[tid] }.compact.first
          groups[first ? first['group'] : 'api'] ||= []
          groups[first ? first['group'] : 'api'] << tid
        end

        groups.keys.each do |g|
          b << "<h2>#{esc(Runner::GROUP_TITLES.fetch(g, g))}</h2>\n"
          b << "<table class=\"bench compare\">\n<tr><th>Тест</th>"
          cols.each { |c| b << "<th class=\"num\">#{esc(c)}</th>" }
          b << "</tr>\n"
          groups[g].each do |tid|
            base_r = by_run_test.first[tid]
            name = base_r ? (base_r['name'] || tid) : tid
            unit = base_r ? base_r['unit'] : nil
            higher = base_r ? base_r['higher_is_better'] : false
            b << "<tr><td>#{esc(name)}</td>"
            datas.each_with_index do |_d, i|
              r = by_run_test[i][tid]
              if r.nil? || r['value'].nil?
                b << '<td class="num muted">—</td>'
                next
              end
              cell = fmt(r['value'], unit)
              unless i.zero?
                reason = base_r.nil? ? 'нет в базовом прогоне' : incompatibility_reason(base_r, r)
                basev = base_r && base_r['value']
                if reason
                  warnings << "#{name}: колонка #{cols[i]} — #{reason}"
                elsif basev && basev.positive?
                  rel = (r['value'] / basev - 1) * 100
                  cls = rel.abs < 3 ? 'same' : (higher ? (rel.positive? ? 'better' : 'worse') : (rel.negative? ? 'better' : 'worse'))
                  cell << " <span class=\"#{cls}\">#{rel >= 0 ? '+' : ''}#{rel.round(1)}%</span>"
                end
              end
              b << "<td class=\"num#{i.zero? ? ' base' : ''}\">#{cell}</td>"
            end
            b << '</tr>'
          end
          b << "</table>\n"
        end

        unless warnings.empty?
          b << "<h2>Несовместимые пары (без процентов)</h2>\n<ul>\n"
          warnings.uniq.each { |w| b << "<li class=\"muted\">#{esc(w)}</li>\n" }
          b << "</ul>\n"
        end
        b << "</body>\n</html>\n"
        b
      end

      # ------------------------------------------------------------------ misc

      def fmt(v, unit)
        return '—' if v.nil?

        if unit == 'fps'
          "#{v.to_f.round(1)} fps"
        else
          v.to_f >= 1000 ? "#{(v.to_f / 1000).round(2)} с" : "#{v.to_f.round(1)} мс"
        end
      end

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def css
        <<~CSS
          <style>
          body { font-family: "Segoe UI", Arial, sans-serif; margin: 24px auto; max-width: 1100px;
                 color: #2e3440; background: #fbfbfd; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin: 26px 0 8px; color: #3b4252; }
          table { border-collapse: collapse; width: 100%; margin: 8px 0; font-size: 13px; }
          th, td { border: 1px solid #dfe1e6; padding: 5px 9px; text-align: left; vertical-align: middle; }
          th { background: #eceff4; font-weight: 600; }
          table.meta { width: auto; min-width: 420px; }
          table.meta th { width: 180px; }
          td.num, th.num { text-align: right; white-space: nowrap; }
          tr.err td { background: #f7e3e3; }
          .muted { color: #7b8394; font-size: 12px; }
          .base { background: #f2f4f8; }
          .better { color: #2e7d32; font-size: 11px; }
          .worse { color: #c62828; font-size: 11px; }
          .same { color: #7b8394; font-size: 11px; }
          </style>
        CSS
      end
    end
  end
end
