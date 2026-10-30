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
require File.join(File.dirname(__FILE__), 'wave_tool.rb')
require File.join(File.dirname(__FILE__), 'environment.rb')
require File.join(File.dirname(__FILE__), 'score.rb')
require File.join(File.dirname(__FILE__), 'runner.rb')
require File.join(File.dirname(__FILE__), 'report.rb')
require File.join(File.dirname(__FILE__), 'sequencer.rb')
require File.join(File.dirname(__FILE__), 'command.rb')

module Dn1supBenchmark
  VERSION   = '0.7.1'.freeze
  PLUG_ROOT = File.dirname(__FILE__).freeze
  TOOLBAR_NAME = 'DN1Sup Benchmark'.freeze
  CMD_TOOLTIP  = 'DN1Sup Benchmark: панель'.freeze

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
      menu.add_item('Прогнать…')                    { safe { run_benchmark } }
      menu.add_item('Отменить прогон')              { safe { Sequencer.cancel } }
      menu.add_separator
      menu.add_item('Открыть последний отчёт')      { safe { open_last_report } }
      menu.add_item('Открыть папку отчётов')        { safe { open_reports_dir } }
      menu.add_separator
      menu.add_item('О расширении')                 { about }
      setup_toolbar
    end

    # Панель инструментов с кнопкой запуска панели. Тулбар через API не
    # удаляется, поэтому кнопка создаётся один раз: после горячей перезагрузки
    # UI::Toolbar.new возвращает существующую панель, а блок старой кнопки
    # ссылается на константу модуля, которая к этому моменту указывает уже на
    # новый код (паттерн dn1sup-плагинов).
    def setup_toolbar
      return unless defined?(UI::Toolbar)

      toolbar = UI::Toolbar.new(TOOLBAR_NAME)
      return if toolbar.any? { |c| c.tooltip == CMD_TOOLTIP }

      cmd = UI::Command.new('Панель бенчмарка') do
        Dn1supBenchmark.show_panel if defined?(Dn1supBenchmark)
      end
      cmd.menu_text = 'Панель бенчмарка…'
      cmd.tooltip = CMD_TOOLTIP
      cmd.status_bar_text = 'Открыть панель бенчмарка'
      svg = File.join(PLUG_ROOT, 'icons', 'bench.svg')
      if File.exist?(svg) && defined?(Sketchup) && Sketchup.respond_to?(:version) && Sketchup.version.to_i >= 16
        cmd.small_icon = svg
        cmd.large_icon = svg
      else
        cmd.small_icon = File.join(PLUG_ROOT, 'icons', 'bench_16.png')
        cmd.large_icon = File.join(PLUG_ROOT, 'icons', 'bench_24.png')
      end
      toolbar.add_item(cmd)
      toolbar.restore
    rescue StandardError => e
      puts "[dn1sup_benchmark] Не удалось создать панель инструментов: #{e.message}"
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
                    "Пять категорий: моделирование сложной модели, инструменты SketchUp " \
                    "(API-эквиваленты), FPS вьюпорта на тяжёлой сцене, волна из кубиков " \
                    "100×100 мм с оборотом камеры, файл ~130 МБ (сохранение/загрузка). " \
                    "Набор один, полный прогон ~1 минута. Отчёты и сравнение прогонов.\n\n" \
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

    def run_benchmark
      if Sequencer.running?
        UI.messagebox('Прогон уже идёт — сначала отмените или дождитесь завершения.')
        return
      end
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('Нет активной модели — прогону нужна открытая модель.')
        return
      end
      # Согласие пользователя: бенчмарк временно создаёт и откатывает
      # геометрию в ТЕКУЩЕЙ модели; тест файла собирает файл во временной
      # папке. Подтверждение обязательно перед каждым прогоном.
      params = Runner.suite_params
      preview = "Набор тестов: v#{Runner::SUITE_VERSION} (5 категорий, полный прогон ~1 минута)\n" \
                "Модель: #{model.title}\n" \
                "Повторов на тест: #{params['iters']}\n" \
                "Файл: цель ~#{params['target_mb']} МБ " \
                "(генерация текстур и сохранение — большая часть минуты)\n\n" \
                'Бенчмарк временно создаёт и откатывает геометрию в текущей модели. ' \
                'Сохраните модель и не переключайте вкладки до конца прогона. ' \
                'Волна видна во вьюпорте; файл открывается в отдельной вкладке ' \
                'и удаляется.\n\nЗапустить?'
      if UI.messagebox(preview, UI::MB_OKCANCEL) != UI::IDOK
        return
      end
      if UI.messagebox("#{Runner::SUITE_WARNING}\n\nЗапустить?", UI::MB_OKCANCEL) != UI::IDOK
        return
      end

      puts "[dn1sup_benchmark] старт прогона (набор v#{Runner::SUITE_VERSION})"
      Sequencer.start
    end
  end
end

Dn1supBenchmark.setup!
