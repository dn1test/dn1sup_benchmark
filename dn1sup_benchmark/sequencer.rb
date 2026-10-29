# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/sequencer.rb — неблокирующий секвенсор прогона.
#
# Проходит шаги Runner.steps на одноразовых UI.start_timer: между шагами
# управление возвращается UI-потоку — вьюпорт перерисовывается, и FPS-метр
# (Tool#draw + view.invalidate) считает честные кадры.
#
# Потребитель прогресса — произвольный callable (proc/lambda), получающий
# хеш-события: 'start', 'step', 'step_done', 'fps_tick', 'finish', 'error'.
# Меню использует его с puts-логгером, HtmlDialog — с рассылкой в JavaScript.
#
# Отмена (Runner.cancel!): проверяется перед каждым шагом и в опросе FPS;
# незавершённый тест прерывается исключением Cancelled, сцена откатывается,
# отчёт сохраняется со статусом прогона 'cancelled'.
# =============================================================================

module Dn1supBenchmark
  module Sequencer
    class << self
      def running?
        @running == true
      end

      # Запуск прогона единственным набором. on_event — callable или nil.
      # Возвращает false, если прогон уже идёт (одновременные прогоны запрещены).
      def start(on_event = nil)
        return false if running?

        @running = true
        @event = on_event
        @steps = Runner.steps
        @total = @steps.size
        @done = 0
        emit('start', 'profile' => Runner::SUITE_PROFILE, 'total' => @total)
        execute(@steps)
        true
      rescue StandardError => e
        @running = false
        emit('error', 'class' => e.class.name, 'message' => e.message)
        raise
      end

      def cancel
        Runner.cancel!
      end

      private

      def execute(steps)
        return conclude if Runner.cancelled?

        step = steps.shift
        return conclude if step.nil?

        @last_label = step['label'] || step['name']
        emit('step', 'label' => @last_label, 'index' => @done + 1, 'total' => @total)
        case step['kind']
        when 'fps', 'wave'
          Runner.perform(step)
          poll_fps(step, steps)
        when 'storage_open'
          # Открытие файла асинхронно в любой перегрузке open_file (SU2024+):
          # одноразовые таймеры после вызова теряются — ждём повторяющимся
          # таймером, как FPS-шаги.
          Runner.perform(step)
          poll_storage(step, steps)
        when 'finish'
          summary = Runner.perform(step)
          @running = false
          emit('finish', summary.is_a?(Hash) ? summary : { 'status' => 'no_run' })
        else
          result = Runner.perform(step)
          if result == :in_progress
            # Кусочная работа (тяжёлые сцены/тесты): переставляем шаг в
            # начало очереди — UI-поток между порциями остаётся свободным,
            # панель получает события прогресса, отмена срабатывает мгновенно.
            pr = Runner.task_progress
            emit('chunk', 'label' => @last_label, 'done' => pr['done'],
                 'total' => pr['total'], 'phase' => pr['phase'], 'phases' => pr['phases'])
            steps.unshift(step)
            UI.start_timer(0.001, false) { execute(steps) }
            return
          end
          @done += 1
          emit('step_done', 'label' => @last_label, 'index' => @done, 'total' => @total, 'result' => result.to_s)
          UI.start_timer(0.05, false) { execute(steps) }
        end
      rescue Runner::ModelChanged
        # Активная модель сменилась — НИКАКОЙ очистки (close_scene защищён
        # собственным guard-ом, но и FPS-инструмент снимать здесь не будем:
        # select_tool не должен трогать чужую модель; авто-стоп FPS по
        # таймауту завершится сам). Состояние прогона сбрасываем полностью,
        # отчёт не сохраняем: данные неполные и относятся к чужой сессии.
        @running = false
        Runner.abort_run!
        puts '[dn1sup_benchmark] прогон остановлен: активная модель изменилась'
        emit('error', 'class' => 'ModelChanged',
                      'message' => 'активная модель изменилась посреди прогона — прогон остановлен, отчёт не сохранён')
      rescue StandardError => e
        @running = false
        Runner.fps_stop_tool
        Runner.close_scene
        puts "[dn1sup_benchmark] прогон прерван: #{e.class}: #{e.message}"
        emit('error', 'class' => e.class.name, 'message' => e.message)
      end

      # FPS/wave-шаги асинхронные: инструмент работает в UI-потоке, опрашиваем
      # повторяющимся таймером до готовности (таймаут от Runner, или отмена).
      def poll_fps(step, steps)
        waited = 0.0
        limit = Runner.async_step_limit
        timer = UI.start_timer(0.4, true) do
          waited += 0.4
          if Runner.fps_ready? || waited > limit || Runner.cancelled?
            UI.stop_timer(timer)
            Dn1supBenchmark.timers.delete(timer)
            Runner.fps_collect
            @done += 1
            emit('step_done', 'label' => step['name'], 'index' => @done, 'total' => @total,
                              'result' => Runner.cancelled? ? 'отменено' : 'ok')
            UI.start_timer(0.05, false) { execute(steps) }
          else
            emit('fps_tick', 'label' => step['name'], 'waited_s' => waited.round(1))
          end
        end
        Dn1supBenchmark.track_timer(timer)
      end

      # Открытие файла: тик опрашивает Runner.storage_open_tick; :in_progress —
      # файл ещё грузится (или стартовала следующая попытка), строка — шаг
      # завершён (успех/отмена/пропуск), передаём ход следующему шагу.
      def poll_storage(step, steps)
        timer = UI.start_timer(0.3, true) do
          res = Runner.storage_open_tick
          if res == :in_progress
            pr = Runner.task_progress
            emit('chunk', 'label' => step['label'], 'done' => pr['done'],
                 'total' => pr['total'])
          else
            UI.stop_timer(timer)
            Dn1supBenchmark.timers.delete(timer)
            @done += 1
            emit('step_done', 'label' => step['label'], 'index' => @done,
                              'total' => @total, 'result' => res.to_s)
            UI.start_timer(0.05, false) { execute(steps) }
          end
        end
        Dn1supBenchmark.track_timer(timer)
      rescue StandardError => e
        @running = false
        Runner.fps_stop_tool
        Runner.close_scene
        puts "[dn1sup_benchmark] poll_storage прерван: #{e.class}: #{e.message}"
        emit('error', 'class' => e.class.name, 'message' => e.message)
      end

      # Завершение: по отмене — остановить FPS-инструмент и откатить сцену,
      # затем в любом случае сохранить отчёт.
      def conclude
        if Runner.cancelled?
          Runner.fps_stop_tool
          Runner.close_scene
        end
        summary = Runner.finish_run
        @running = false
        emit('finish', summary.is_a?(Hash) ? summary : { 'status' => 'no_run' })
      rescue StandardError => e
        @running = false
        emit('error', 'class' => e.class.name, 'message' => e.message)
      end

      # fields — хеш со строковыми ключами (без Symbol: он уйдёт в JSON).
      def emit(name, fields = {})
        return if @event.nil?

        payload = { 'event' => name }
        fields.each { |k, v| payload[k.to_s] = v }
        begin
          @event.call(payload)
        rescue StandardError => e
          puts "[dn1sup_benchmark] обработчик прогресса упал: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
