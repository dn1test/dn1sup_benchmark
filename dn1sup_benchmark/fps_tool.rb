# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/fps_tool.rb — FPS-метр вьюпорта.
#
# Паттерн: активный Tool считает кадры в #draw и в конце каждого кадра зовёт
# view.invalidate — SketchUp перерисовывает вид непрерывно, и мы получаем
# фактический FPS рендера на построенной сцене. Режим :orbit на каждом кадре
# чуть поворачивает камеру вокруг цели — имитация орбиты пользователя.
#
# ВАЖНО: Tool сам себя НЕ снимает (select_tool из #draw опасен) — снятие
# делает внешний код (Runner.fps_collect / ensure-путь). Автостоп — по
# длительности и лимиту кадров: invalidate просто прекращается, кадры
# останавливаются, результат лежит в #result.
# =============================================================================

module Dn1supBenchmark
  class FpsTool
    MAX_FRAMES = 100_000
    ANGLE_PER_FRAME = 0.03 # рад (~1.7°) — шаг орбиты за кадр

    attr_reader :result

    def initialize(duration_s, orbit)
      @duration = duration_s.to_f
      @orbit = orbit ? true : false
      @frames = 0
      @result = nil
      @t0 = nil
      @eye = nil
      @target = nil
      @up = nil
      @angle = 0.0
    end

    def orbit?
      @orbit
    end

    def activate
      cam = Sketchup.active_model.active_view.camera
      @eye = cam.eye.clone
      @target = cam.target.clone
      @up = Geom::Vector3d.new(0, 0, 1)
      @angle = 0.0
      @frames = 0
      @t0 = Dn1supBenchmark.monotonic
    end

    def draw(view)
      return unless @result.nil?
      return unless @t0

      @frames += 1
      elapsed = Dn1supBenchmark.monotonic - @t0
      if elapsed >= @duration || @frames >= MAX_FRAMES
        finish(elapsed)
        return
      end

      orbit_step(view) if @orbit
      view.invalidate
    end

    # Панель инструментов деактивируется внешним кодом; повторная активация
    # того же экземпляра не предполагается.
    def deactivate(view); end

    def suspend(view); end

    def resume(view)
      @t0 = Dn1supBenchmark.monotonic
      @frames = 0
    end

    # Ранний внешний стоп: зафиксировать результат по текущим кадрам.
    def stop_now
      finish(Dn1supBenchmark.monotonic - @t0) if @result.nil? && @t0
      @result
    end

    private

    def finish(elapsed)
      elapsed = 0.0 if elapsed < 0
      fps = elapsed > 0 ? @frames / elapsed : 0.0
      @result = {
        'frames' => @frames,
        'elapsed_s' => (elapsed * 1000).round / 1000.0,
        'fps' => (fps * 10).round / 10.0,
        'mode' => @orbit ? 'orbit' : 'static'
      }
    end

    # Горизонтальная орбита: eye вращается вокруг target вокруг оси Z.
    def orbit_step(view)
      @angle += ANGLE_PER_FRAME
      e = @eye - @target
      cos = Math.cos(@angle)
      sin = Math.sin(@angle)
      v = Geom::Vector3d.new(e.x * cos - e.y * sin, e.x * sin + e.y * cos, e.z)
      eye = @target.offset(v)
      view.camera = Sketchup::Camera.new(eye, @target, @up)
    rescue StandardError
      # Смена камеры из #draw не поддержана — уходим в статичный режим,
      # тест продолжает считаться честно (invalidate-луп).
      @orbit = false
    end
  end
end
