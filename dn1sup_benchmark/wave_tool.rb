# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/wave_tool.rb — анимация «волна из кубиков» (suite v4).
#
# Полотно N×N кубов 100×100×100 мм (сцена wave, Runner строит кубы как
# инстансы одного определения). Диагональная бегущая волна:
#     z(x, y, t) = A · sin( 2π·(x + y)/λ − 2π·t/T )
# Camera: полный оборот 360° вокруг полотна за длительность замера — волна
# видна со всех сторон. FPS считается так же, как FpsTool (счётчик кадров
# Tool#draw + view.invalidate; Ruby-сторона, не GPU-счётчик).
#
# Геометрия обновляется ПАКЕТАМИ Entities#transform_entities из отдельного
# повторяющегося таймера ~30 Гц (не из #draw): дельты z по инстансам
# квантуются до 1 мм, инстансы с одинаковой дельтой сдвигаются одним
# вызовом. Время каждого обновления пишется в result['update_ms'] —
# это метрика wave_update_ms.
#
# ВАЖНО (как FpsTool): Tool сам себя НЕ снимает — снятие делает внешний
# код (Runner.fps_collect → select_tool(nil)); таймер останавливается
# сам на следующем тике после завершения и в deactivate.
# =============================================================================

module Dn1supBenchmark
  class WaveTool
    MAX_FRAMES = 100_000
    TIMER_HZ = 30.0        # частота обновления геометрии
    AMPLITUDE_MM = 300.0   # амплитуда волны
    WAVELENGTH_CELLS = 8.0 # длина волны в клетках полотна (клетка = 100 мм)
    PERIOD_S = 3.0         # период бегущей волны
    CELL_MM = 100.0
    QUANT_MM = 1.0         # квант дельты z для пакетной трансформации

    attr_reader :result

    # instances/positions — массивы равной длины из Scenes.build_wave;
    # duration_s — длительность замера.
    def initialize(duration_s, instances, positions)
      @duration = duration_s.to_f
      @instances = instances
      @base = positions
      @z = Array.new(instances.size, 0.0) # текущий z каждого куба, мм
      @frames = 0
      @result = nil
      @update_ms = []
      @timer_id = nil
      @t0 = nil
    end

    # Чистая математика волны (мм) — для юнит-тестов без SketchUp.
    def self.wave_z(x_mm, y_mm, t_s)
      k = 2.0 * Math::PI / (WAVELENGTH_CELLS * CELL_MM)
      AMPLITUDE_MM * Math.sin(k * (x_mm + y_mm) - 2.0 * Math::PI * t_s / PERIOD_S)
    end

    def activate
      cam = Sketchup.active_model.active_view.camera
      @eye = cam.eye.clone
      @target = cam.target.clone
      @up = Geom::Vector3d.new(0, 0, 1)
      @frames = 0
      @t0 = Dn1supBenchmark.monotonic
      @timer_id = UI.start_timer(1.0 / TIMER_HZ, true) { tick_update }
      Dn1supBenchmark.track_timer(@timer_id)
    end

    def draw(view)
      return unless @result.nil? && @t0

      @frames += 1
      elapsed = Dn1supBenchmark.monotonic - @t0
      if elapsed >= @duration || @frames >= MAX_FRAMES
        finish(elapsed)
        return
      end

      orbit_step(view, elapsed)
      view.invalidate
    end

    def deactivate(_view)
      stop_timer
    end

    def suspend(_view); end

    def resume(_view)
      @t0 = Dn1supBenchmark.monotonic
      @frames = 0
    end

    # Ранний внешний стоп: зафиксировать результат по текущим кадрам.
    def stop_now
      finish(Dn1supBenchmark.monotonic - @t0) if @result.nil? && @t0
      @result
    end

    private

    # Обновление геометрии из таймера: дельты → корзины по 1 мм → один
    # transform_entities на корзину. Счёт времени — вокруг всей пакета.
    def tick_update
      if @result || @t0.nil?
        stop_timer
        return
      end

      t = Dn1supBenchmark.monotonic - @t0
      t0ms = Dn1supBenchmark.monotonic
      begin
        buckets = {}
        @base.each_with_index do |(x, y), k|
          target = WaveTool.wave_z(x, y, t)
          delta = ((target - @z[k]) / QUANT_MM).round * QUANT_MM
          if delta != 0.0
            buckets[delta] ||= []
            buckets[delta] << @instances[k]
            @z[k] += delta
          end
        end
        ents = Sketchup.active_model.entities
        buckets.each do |delta, list|
          ents.transform_entities(Geom::Transformation.new([0, 0, delta.mm]), list)
        end
      rescue StandardError
        nil # ошибка обновления не должна ронять замер кадров
      end
      @update_ms << ((Dn1supBenchmark.monotonic - t0ms) * 1000.0)
    end

    # Полный оборот камеры за длительность: угол растёт от elapsed, а не
    # от числа кадров — при пропуске кадров оборот всё равно полный.
    def orbit_step(view, elapsed)
      angle = 2.0 * Math::PI * elapsed / @duration
      e = @eye - @target
      cos = Math.cos(angle)
      sin = Math.sin(angle)
      v = Geom::Vector3d.new(e.x * cos - e.y * sin, e.x * sin + e.y * cos, e.z)
      eye = @target.offset(v)
      view.camera = Sketchup::Camera.new(eye, @target, @up)
    rescue StandardError
      # Смена камеры из #draw не поддержана — волна продолжится без вращения.
      nil
    end

    def finish(elapsed)
      elapsed = 0.0 if elapsed < 0
      fps = elapsed > 0 ? @frames / elapsed : 0.0
      @result = {
        'frames' => @frames,
        'elapsed_s' => (elapsed * 1000).round / 1000.0,
        'fps' => (fps * 10).round / 10.0,
        'update_ms' => @update_ms
      }
    end

    def stop_timer
      return if @timer_id.nil?

      begin
        UI.stop_timer(@timer_id)
      rescue StandardError
        nil
      end
      @timer_id = nil
    end
  end
end
