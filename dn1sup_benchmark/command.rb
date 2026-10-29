# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/command.rb — программный вход для прогона (меню и диалог
# используют Sequencer; эти методы дергают шаги напрямую — их вызывают тесты
# и внешний оркестратор через мост, шаг за шагом, с паузами на FPS).
# =============================================================================

module Dn1supBenchmark
  class << self
    # План шагов прогона (для внешнего оркестратора).
    def benchmark_steps
      Runner.steps
    end

    # Краткое описание плана и параметров набора (без исполнения).
    def benchmark_plan
      Runner.plan_preview
    end

    # Выполнить один шаг. Шаг сцены может вернуть :in_progress — тяжёлая
    # работа режется на порции ~1 с; вызывайте benchmark_perform(step) в
    # цикле до результата-строки (пауза между вызовами отдаёт UI-поток).
    # Для :fps нужен внешний такт между perform и fps_collect, чтобы
    # UI-поток отрисовал кадры.
    def benchmark_perform(step)
      Runner.perform(step)
    end

    # Забрать результат FPS-замера (после паузы) и снять инструмент.
    def benchmark_fps_collect
      Runner.fps_collect
    end

    # Отмена текущего прогона (проверяется между шагами и повторами).
    def benchmark_cancel
      Runner.cancel!
    end

    # Текущий стейт прогона (для диагностики; не для записи).
    def benchmark_state
      Runner.run_data
    end

    # Данные последнего завершённого прогона (как в сохранённом JSON).
    def benchmark_last_run
      Runner.last_run_data
    end

    # Сравнительный отчёт по путям к JSON прошлых прогонов.
    def benchmark_compare(json_paths)
      Report.compare(json_paths)
    end

    # Список сохранённых прогонов (для выбора в сравнении).
    def benchmark_runs
      Report.list_runs
    end
  end
end
