# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/main.rb — основная логика расширения «DN1Sup Benchmark».
#
# Шаблон рассчитан на горячую перезагрузку (ext_reload MCP-сервера sketchup-dev):
#   • все меню/таймеры регистрируются через track_* и снимаются в unload!;
#   • setup! защищён от повторного входа;
#   • код не использует file_loaded?.
#
# Прогон идёт через Sequencer (sequencer.rb) — неблокирующий секвенсор на
# одноразовых UI.start_timer. Диалог (UI::HtmlDialog) грузится лениво при
# первом обращении через меню — он открывается ТОЛЬКО действием пользователя
# (открывать окна из консоли/моста запрещено правилами безопасности).
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
require File.join(File.dirname(__FILE__), 'environment.rb')
require File.join(File.dirname(__FILE__), 'score.rb')
require File.join(File.dirname(__FILE__), 'runner.rb')
require File.join(File.dirname(__FILE__), 'report.rb')
require File.join(File.dirname(__FILE__), 'sequencer.rb')
require File.join(File.dirname(__FILE__), 'command.rb')

module Dn1supBenchmark
  VERSION   = '0.3.1'.freeze
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
      if defined?(Dialog) && Dialog.respond_to?(:unload)
        begin
          Dialog.unload
        rescue StandardError
          nil
        end
      end
      true
    end

    # -- интерфейс ---------------------------------------------------------------

    def setup!
      return if @setup_done
      return unless defined?(UI) && UI.respond_to?(:menu)

      @setup_done = true
      parent = common_menu
      menu = track_menu(parent, parent.add_submenu('Benchmark'))
      menu.add_item('Панель бенчмарка…')            { safe { show_panel } }
      menu.add_separator
      menu.add_item('Прогнать (small)…')            { safe { run_benchmark('small') } }
      menu.add_item('Прогнать (medium)…')           { safe { run_benchmark('medium') } }
      menu.add_item('Прогнать (large)…')            { safe { run_benchmark('large') } }
      menu.add_item('Отменить прогон')              { safe { Sequencer.cancel } }
      menu.add_separator
      menu.add_item('Открыть последний отчёт')      { safe { open_last_report } }
      menu.add_item('Открыть папку отчётов')        { safe { open_reports_dir } }
      menu.add_separator
      menu.add_item('О расширении')                 { about }
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

    # Диалог грузится лениво (отдельный файл, отдельный require) — открывается
    # только явным действием пользователя, никогда из консоли/моста.
    def show_panel
      require File.join(PLUG_ROOT, 'dialog.rb')
      Dialog.show
    end

    def about
      UI.messagebox("DN1Sup Benchmark v#{VERSION} (набор тестов v#{Runner::SUITE_VERSION})\n\n" \
                    "Бенчмарк производительности SketchUp: чистый Ruby, API, файловые " \
                    "операции, FPS вьюпорта. Отчёты и сравнение прогонов.\n\n" \
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
      pattern = File.join(Report.report_dir, 'bench-*.html').tr('\\', '/')
      files = Dir.glob(pattern).sort_by { |f| File.mtime(f) }
      files.last
    end

    def latest_json_report
      pattern = File.join(Report.report_dir, 'bench-*.json').tr('\\', '/')
      files = Dir.glob(pattern).sort_by { |f| File.mtime(f) }
      files.last
    end

    # Ошибки команд не должны ронять SketchUp — показываем их пользователю.
    def safe
      yield
    rescue StandardError => e
      UI.messagebox("DN1Sup Benchmark: #{e.class}: #{e.message}")
    end

    # -- запуск прогона из меню -----------------------------------------------

    def run_benchmark(profile, overrides = nil)
      if Sequencer.running?
        UI.messagebox('Прогон уже идёт — сначала отмените или дождитесь завершения.')
        return
      end
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('Нет активной модели — прогону нужна открытая модель.')
        return
      end
      # Согласие пользователя (ТЗ §14): бенчмарк временно создаёт и откатывает
      # геометрию в ТЕКУЩЕЙ модели. Подтверждение обязательно перед каждым
      # прогоном; тяжёлые профили предупреждают дополнительно.
      preview = "Профиль: #{profile}\nМодель: #{model.title}\n" \
                "Повторов на тест: #{Runner.profile_params(profile, overrides)['iters']}\n\n" \
                'Бенчмарк временно создаёт и откатывает геометрию в текущей модели. ' \
                'Сохраните модель и не переключайте вкладки до конца прогона.\n\nЗапустить?'
      if UI.messagebox(preview, UI::MB_OKCANCEL) != UI::IDOK
        return
      end
      warning = Runner.profile_warning(profile)
      if warning && UI.messagebox("#{warning}\n\nЗапустить?", UI::MB_OKCANCEL) != UI::IDOK
        return
      end

      puts "[dn1sup_benchmark] старт прогона #{profile}"
      Sequencer.start(profile, overrides)
    end
  end
end

Dn1supBenchmark.setup!
