# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/command.rb — программный вход для прогона (меню использует
# секвенсор из main.rb; эти методы дергают шаги напрямую — их вызывают тесты
# и внешний оркестратор через мост, шаг за шагом, с паузами на FPS).
# =============================================================================

module Dn1supBenchmark
  class << self
    # План шагов прогона (для внешнего оркестратора).
    def benchmark_steps(profile = 'quick')
      Runner.steps(profile)
    end

    # Выполнить один шаг (кроме :fps — тем нужен внешний такт между perform
    # и fps_collect, чтобы UI-поток отрисовал кадры).
    def benchmark_perform(step)
      Runner.perform(step)
    end

    # Забрать результат FPS-замера (после паузы) и снять инструмент.
    def benchmark_fps_collect
      Runner.fps_collect
    end

    # Текущий стейт прогона (для диагностики; не для записи).
    def benchmark_state
      Runner.run_data
    end

    # Сравнительный отчёт по путям к JSON прошлых прогонов.
    def benchmark_compare(json_paths)
      Report.compare(json_paths)
    end
  end
end
