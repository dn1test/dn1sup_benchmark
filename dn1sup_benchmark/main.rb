# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/main.rb — основная логика расширения «DN1Sup Benchmark».
#
# Шаблон рассчитан на горячую перезагрузку (ext_reload MCP-сервера sketchup-dev):
#   • все меню/таймеры регистрируются через track_* и снимаются в unload!;
#   • setup! защищён от повторного входа;
#   • код не использует file_loaded?.
#
# Прогон из меню идёт через секвенсор на одноразовых UI.start_timer: между
# шагами управление возвращается UI-потоку — вьюпорт перерисовывается, и
# FPS-метр (Tool#draw + view.invalidate) считает честные кадры.
# =============================================================================

require 'sketchup.rb'

# monotonic нужен всем модулям; объявляем до их загрузки (Ruby позволяет
# переоткрыть module ниже по файлу).
module Dn1supBenchmark
  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

require File.join(File.dirname(__FILE__), 'png_gen.rb')
require File.join(File.dirname(__FILE__), 'scenes.rb')
require File.join(File.dirname(__FILE__), 'fps_tool.rb')
require File.join(File.dirname(__FILE__), 'runner.rb')
require File.join(File.dirname(__FILE__), 'report.rb')
require File.join(File.dirname(__FILE__), 'command.rb')

module Dn1supBenchmark
  VERSION   = '0.1.0'.freeze
  PLUG_ROOT = File.dirname(__FILE__).freeze

  class << self
    # -- отслеживаемые ресурсы (снимаются в unload!) ---------------------------

    def menu_pairs; @menu_pairs ||= []; end
    def timers;     @timers     ||= []; end

    def track_menu(parent, item)
      menu_pairs << [parent, item]
      item
    end

    def track_timer(id)
      timers << id
      id
    end

    attr_accessor :last_report

    def unload!
      menu_pairs.each do |parent, item|
        begin
          parent.remove_item(item)
        rescue StandardError
          nil
        end
      end
      timers.each do |id|
        begin
          UI.stop_timer(id)
        rescue StandardError
          nil
        end
      end
      Runner.fps_stop_tool
      @sequencer_timer = nil
      true
    end

    # -- интерфейс ---------------------------------------------------------------

    def setup!
      return if @setup_done
      return unless defined?(UI) && UI.respond_to?(:menu)

      @setup_done = true
      parent = common_menu
      menu = track_menu(parent, parent.add_submenu('Benchmark'))
      menu.add_item('Прогнать бенчмарк (полный)…') { safe { run_benchmark('full') } }
      menu.add_item('Быстрый прогон (quick)…')     { safe { run_benchmark('quick') } }
      menu.add_separator
      menu.add_item('Открыть последний отчёт')     { safe { open_last_report } }
      menu.add_item('Открыть папку отчётов')       { safe { open_reports_dir } }
      menu.add_separator
      menu.add_item('О расширении')               { about }
    end

    # Общий DN1Sup-подменю, если какой-то dn1sup-плагин его уже создал;
    # иначе — прямой подпункт Extensions.
    def common_menu
      if defined?(Dn1sup) && Dn1sup.respond_to?(:common_menu)
        Dn1sup.common_menu
      else
        UI.menu('Extensions')
      end
    end

    def about
      UI.messagebox("DN1Sup Benchmark v#{VERSION}\n\n" \
                    "Бенчмарк производительности SketchUp: FPS вьюпорта на сложных " \
                    "сценах, редактирование, навигация по иерархии, текстуры.\n\n" \
                    "Отчёты: #{Report.report_dir}")
    end

    def open_last_report
      path = @last_report || latest_report
      if path && File.exist?(path)
        UI.openURL("file:///#{path.tr('\\', '/')}")
      else
        UI.messagebox('Отчётов пока нет — прогоните бенчмарк.')
      end
    end

    def open_reports_dir
      dir = Report.report_dir
      UI.openURL("file:///#{dir.tr('\\', '/')}")
    end

    def latest_report
      files = Dir.glob(File.join(Report.report_dir, 'bench-*.html')).sort_by(&:mtime)
      files.last
    end

    # Ошибки команд не должны ронять SketchUp — показываем их пользователю.
    def safe
      yield
    rescue StandardError => e
      UI.messagebox("DN1Sup Benchmark: #{e.class}: #{e.message}")
    end

    # -- секвенсор прогона (из меню) ----------------------------------------------

    # Проходит шаги Runner.steps: :sync-шаги выполняются сразу, :fps — стартует
    # метр и опрашивается повторяющимся таймером (0.4 с) до готовности.
    def run_benchmark(profile)
      steps = Runner.steps(profile).dup
      puts "[dn1sup_benchmark] старт прогона #{profile} (#{steps.size} шагов)"
      execute_steps(steps)
    end

    def execute_steps(steps)
      step = steps.shift
      if step.nil?
        finish_menu_run
        return
      end
      puts "[dn1sup_benchmark] шаг: #{step['label'] || step['name']}"
      if step['kind'] == 'fps'
        Runner.perform(step)
        poll_fps(steps)
      else
        Runner.perform(step)
        UI.start_timer(0.05, false) { execute_steps(steps) }
      end
    rescue StandardError => e
      UI.messagebox("Прогон прерван: #{e.class}: #{e.message}")
      Runner.fps_stop_tool
    end

    def poll_fps(steps)
      waited = 0.0
      timer = UI.start_timer(0.4, true) do
        waited += 0.4
        if Runner.fps_ready? || waited > 30.0
          UI.stop_timer(timer)
          timers.delete(timer)
          Runner.fps_collect
          UI.start_timer(0.05, false) { execute_steps(steps) }
        end
      end
      track_timer(timer)
    end

    def finish_menu_run
      summary = Runner.finish_run
      if summary.is_a?(Hash) && summary['status'] == 'ok'
        UI.messagebox("Прогон завершён: тестов #{summary['tests']}, " \
                      "ошибок #{summary['errors']}.\n\nОтчёт:\n#{summary['html']}")
      end
    rescue StandardError => e
      UI.messagebox("Не удалось завершить прогон: #{e.class}: #{e.message}")
    end
  end
end

Dn1supBenchmark.setup!
