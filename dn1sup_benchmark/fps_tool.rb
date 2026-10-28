# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/fps_tool.rb — FPS-метр вьюпорта.
#
# Паттерн: активный Tool считает кадры в #draw и в конце каждого кадра зовёт
# view.invalidate — SketchUp перерисовывает вид непрерывно, и мы получаем
# фактический FPS рендера на построенной сцене. Это замер Ruby-стороны
# (счётчик кадров), а НЕ показания GPU — источник фиксируется в отчёте.
#
# Режимы (шаг на каждый кадр, имитация действий пользователя):
#   static — статичный вид, только invalidate-луп;
#   orbit  — поворот камеры вокруг цели (шаг ~1.7°);
#   pan    — сдвиг камеры и цели вправо с отскоком в конце пролёта;
#   zoom   — приближение/удаление пинг-понгом (дистанция eye→target).
#
# Режим переключения страниц (Pages#selected_page=) УДАЛЁН: применение
# страницы внутри открытой undo-операции фиксирует транзакцию ядра, после
# чего abort уже не откатывает контент модели (инцидент 2026-10-28, SU2027).
# Переключение сцен — только ручной сценарий (см. README).
#
# ВАЖНО: Tool сам себя НЕ снимает (select_tool из #draw опасен) — снятие
# делает внешний код (Runner.fps_collect / ensure-путь). Автостоп — по
# длительности и лимиту кадров: invalidate просто прекращается, кадры
# останавливаются, результат лежит в #result.
# =============================================================================

module Dn1supBenchmark
  class FpsTool
    MAX_FRAMES = 100_000
    ANGLE_PER_FRAME = 0.03   # рад (~1.7°) — шаг орбиты за кадр
    PAN_PER_FRAME = 2.0      # дюймов за кадр — панорамирование
    ZOOM_PER_FRAME = 0.02    # доля дистанции за кадр
    ZOOM_MIN = 20.0          # дюймов — ближняя граница зума
    ZOOM_MAX = 2000.0        # дюймов — дальняя граница зума

    MODES = %w[static orbit pan zoom].freeze

    attr_reader :result

    # mode — строка из MODES (true/false из старых вызовов маппятся в orbit/static).
    def initialize(duration_s, mode = 'static')
      @duration = duration_s.to_f
      @mode = normalize_mode(mode)
      @frames = 0
      @result = nil
      @t0 = nil
      @eye = nil
      @target = nil
      @up = nil
      @angle = 0.0
      @pan_dir = 1
      @zoom_dir = 1
    end

    def mode
      @mode
    end

    def orbit?
      @mode == 'orbit'
    end

    def activate
      cam = Sketchup.active_model.active_view.camera
      @eye = cam.eye.clone
      @target = cam.target.clone
      @up = Geom::Vector3d.new(0, 0, 1)
      @angle = 0.0
      @pan_dir = 1
      @pan_origin = cam.eye.clone
      @zoom_dir = 1
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

      case @mode
      when 'orbit' then orbit_step(view)
      when 'pan'   then pan_step(view)
      when 'zoom'  then zoom_step(view)
      end
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

    def normalize_mode(mode)
      case mode
      when true  then 'orbit'
      when false, nil then 'static'
      else
        MODES.include?(mode.to_s) ? mode.to_s : 'static'
      end
    end

    def finish(elapsed)
      elapsed = 0.0 if elapsed < 0
      fps = elapsed > 0 ? @frames / elapsed : 0.0
      @result = {
        'frames' => @frames,
        'elapsed_s' => (elapsed * 1000).round / 1000.0,
        'fps' => (fps * 10).round / 10.0,
        'mode' => @mode
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
      @mode = 'static'
    end

    # Панорамирование: сдвиг eye и target вдоль «правого» вектора камеры.
    # Направление меняется на отскоке у границы пролёта (~10 м).
    def pan_step(view)
      eye = view.camera.eye
      target = view.camera.target
      dir = target - eye
      right = dir * Z_AXIS
      right = right.normalize if right.valid?
      offset = right.transform_scaling(PAN_PER_FRAME * @pan_dir)
      new_eye = eye.offset(offset)
      if @pan_origin && new_eye.distance(@pan_origin) > 400.0
        @pan_dir = -@pan_dir
        @pan_origin = new_eye
      end
      view.camera = Sketchup::Camera.new(new_eye, target.offset(offset), @up)
    rescue StandardError
      @mode = 'static'
    end

    # Зум: дистанция eye→target сжимается/растягивается пинг-понгом.
    def zoom_step(view)
      eye = view.camera.eye
      target = view.camera.target
      v = eye - target
      dist = v.length
      new_dist = dist * (1.0 - ZOOM_PER_FRAME * @zoom_dir)
      @zoom_dir = -@zoom_dir if new_dist < ZOOM_MIN || new_dist > ZOOM_MAX
      new_eye = target.offset(v.transform_scaling(new_dist / dist))
      view.camera = Sketchup::Camera.new(new_eye, target, @up)
    rescue StandardError
      @mode = 'static'
    end
  end
end
