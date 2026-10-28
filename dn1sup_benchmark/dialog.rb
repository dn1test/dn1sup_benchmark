# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/dialog.rb — панель UI::HtmlDialog (вкладки ТЗ §11).
#
# ПРАВИЛА БЕЗОПАСНОСТИ (мастер AGENTS.md):
#   • show() вызывается ТОЛЬКО действием пользователя (меню) — никогда из
#     консоли/моста: окна асинхронны, повторный show плодит окна и роняет Qt;
#   • все action_callback регистрируются ДО show;
#   • unload НЕ закрывает окно (закрывает пользователь), только сбрасывает
#     ссылку и останавливает рассылку событий в закрытое окно.
#
# Прогон идёт через Sequencer; события прогресса доставляются в JS через
# execute_script с guard-ом window.bench (строковые ключи, JSON).
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Dialog
    SETTINGS_KEY = 'settings'

    class << self
      def show
        # Повторный вызов просто поднимает существующее окно наверх.
        if @dlg
          begin
            @dlg.bring_to_front
          rescue StandardError
            nil
          end
          return @dlg
        end

        @dlg = UI::HtmlDialog.new(
          dialog_title: 'DN1Sup Benchmark',
          preferences_key: 'dn1sup_benchmark_dialog',
          width: 960, height: 680,
          resizable: true,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        register_callbacks(@dlg)
        @dlg.set_file(File.join(PLUG_ROOT, 'ui', 'html', 'index.html'))
        @dlg.show
        @dlg
      end

      # Вызывается из Dn1supBenchmark.unload! — окно НЕ закрываем (его закрывает
      # пользователь), только забываем ссылку и глушим рассылку событий.
      def unload
        @dlg = nil
        true
      end

      private

      # ---- доставка данных в JS -------------------------------------------------

      def push(dlg, channel, payload)
        return if dlg.nil?

        json = JSON.generate(payload)
        dlg.execute_script("window.bench && window.bench.receive(#{channel.to_s.inspect}, #{json});")
      rescue StandardError => e
        puts "[dn1sup_benchmark] push(#{channel}) не удался: #{e.class}: #{e.message}"
      end

      def push_event(dlg, event)
        push(dlg, 'event', event)
      end

      # ---- данные для вкладок ------------------------------------------------------

      def overview_data
        meta = Environment.context('—', {})
        last = Runner.last_run_data || read_latest_run
        {
          'environment' => meta,
          'last_run' => last && {
            'file' => last.dig('meta', 'started_at'),
            'profile' => last.dig('meta', 'profile'),
            'run' => last['run'],
            'sketchup' => last.dig('meta', 'sketchup_version'),
            'tests' => (last['results'] || []).size,
            'not_passed' => (last['results'] || []).count { |r| r['status'] != 'passed' },
            'results' => (last['results'] || []).map do |r|
              { 'id' => r['id'], 'name' => r['name'], 'status' => r['status'],
                'unit' => r['unit'], 'value' => r['value'] }
            end,
            'score' => last['score'] || Score.compute(last)
          },
          'reports_dir' => Report.report_dir,
          'running' => Sequencer.running?
        }
      end

      def read_latest_run
        path = Dn1supBenchmark.latest_json_report
        return nil if path.nil?

        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      # ---- колбэки (регистрируются строго до show) ---------------------------------

      def register_callbacks(dlg)
        dlg.add_action_callback('get_overview') do |_ctx|
          push(dlg, 'overview', overview_data)
        end

        dlg.add_action_callback('get_plan') do |_ctx, profile, overrides_json|
          overrides = parse_json(overrides_json)
          push(dlg, 'plan', plan_data(profile, overrides))
        rescue StandardError => e
          push(dlg, 'error', { 'message' => "#{e.class}: #{e.message}" })
        end

        dlg.add_action_callback('start_run') do |_ctx, profile, overrides_json|
          start_run(dlg, profile, parse_json(overrides_json))
        rescue StandardError => e
          push(dlg, 'error', { 'message' => "#{e.class}: #{e.message}" })
        end

        dlg.add_action_callback('cancel_run') do |_ctx|
          Sequencer.cancel
          push(dlg, 'notice', { 'message' => 'Отмена запрошена — остановится после текущего теста' })
        end

        dlg.add_action_callback('get_results') do |_ctx|
          data = Runner.last_run_data || read_latest_run
          push(dlg, 'results', data ? run_results_data(data) : { 'none' => true })
        end

        dlg.add_action_callback('get_runs') do |_ctx|
          push(dlg, 'runs', { 'items' => Report.list_runs(30) })
        end

        dlg.add_action_callback('compare_runs') do |_ctx, paths_json|
          paths = parse_json(paths_json) || []
          datas = paths.map { |p| JSON.parse(File.read(p)) }
          push(dlg, 'compare', Report.compare_data(datas))
        rescue StandardError => e
          push(dlg, 'error', { 'message' => "Сравнение: #{e.class}: #{e.message}" })
        end

        dlg.add_action_callback('save_settings') do |_ctx, settings_json|
          settings = parse_json(settings_json) || {}
          Sketchup.write_default('dn1sup_benchmark', SETTINGS_KEY, JSON.generate(settings))
          push(dlg, 'notice', { 'message' => 'Настройки сохранены' })
        rescue StandardError => e
          push(dlg, 'error', { 'message' => "Настройки: #{e.class}: #{e.message}" })
        end

        dlg.add_action_callback('get_settings') do |_ctx|
          push(dlg, 'settings', load_settings)
        end

        dlg.add_action_callback('open_path') do |_ctx, path, report_kind|
          if report_kind == 'dir'
            UI.openURL("file:///#{path.to_s.tr('\\', '/')}")
          elsif path && File.exist?(path)
            UI.openURL("file:///#{path.tr('\\', '/')}")
          end
        end

        dlg.add_action_callback('open_last_report_path') do |_ctx|
          path = Dn1supBenchmark.last_report || Dn1supBenchmark.latest_report
          if path && File.exist?(path)
            UI.openURL("file:///#{path.tr('\\', '/')}")
          else
            push(dlg, 'notice', { 'message' => 'HTML-отчётов пока нет — прогоните бенчмарк' })
          end
        end
      end

      def parse_json(str)
        return nil if str.nil? || str.to_s.empty?

        JSON.parse(str)
      end

      def plan_data(profile, overrides)
        preview = Runner.plan_preview(profile, overrides)
        by_cat = preview['steps'].group_by { |s| s['category'].to_s }
        preview['categories'] = by_cat.map { |cat, steps| { 'category' => cat, 'count' => steps.size } }
        preview
      end

      def start_run(dlg, profile, overrides)
        if Sequencer.running?
          push(dlg, 'notice', { 'message' => 'Прогон уже идёт' })
          return
        end
        model = Sketchup.active_model
        if model.nil?
          push(dlg, 'error', { 'message' => 'Нет активной модели' })
          return
        end

        # Подтверждение согласия — в UI диалога (кнопка «Запустить» активна
        # только после показа нагрузки), здесь дублируем краткую памятку.
        params = Runner.profile_params(profile, overrides)
        push(dlg, 'notice',
             { 'message' => "Старт (#{profile}): временно создаётся и откатывается геометрия в " \
                            "«#{model.title}». Не переключайте вкладки моделей до конца прогона." })
        puts "[dn1sup_benchmark] старт прогона #{profile} из диалога"
        Sequencer.start(profile, overrides, ->(ev) { push_event(dlg, ev) })
      end

      def run_results_data(data)
        {
          'meta' => data['meta'].slice('sketchup_version', 'profile', 'started_at',
                                       'test_suite_version', 'ruby_version', 'cpu'),
          'run' => data['run'],
          'score' => data['score'] || Score.compute(data),
          'groups' => (data['results'] || []).group_by { |r| r['group'] }.map do |g, rs|
            { 'group' => g, 'title' => Runner::GROUP_TITLES.fetch(g, g),
              'tests' => rs.map do |r|
                { 'id' => r['id'], 'name' => r['name'], 'status' => r['status'],
                  'unit' => r['unit'], 'value' => r['value'],
                  'min' => r['min_ms'] || r['min'], 'max' => r['max_ms'] || r['max'],
                  'p95' => r['p95_ms'], 'repeats' => r['repeat_count'],
                  'ops' => r['ops_per_sec'], 'entities' => r['entities'],
                  'error' => r['error'], 'higher' => r['higher_is_better'] }
              end }
          end
        }
      end

      def load_settings
        raw = Sketchup.read_default('dn1sup_benchmark', SETTINGS_KEY)
        settings = parse_json(raw) || {}
        defaults = { 'profile' => 'small', 'iters' => nil, 'fps_s' => nil, 'doc_enabled' => true }
        defaults.merge(settings)
      rescue StandardError
        { 'profile' => 'small', 'iters' => nil, 'fps_s' => nil, 'doc_enabled' => true }
      end
    end
  end
end
