# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/runner.rb — методика и выполнение бенчмарка (набор v5).
#
# Прогон = последовательность ШАГОВ (Runner.steps), ровно пять категорий ТЗ:
#   1. modeling  — эмуляция моделирования: сложная модель из уникальных
#                  компонентов и вложенных сборок + правка определения,
#                  обход дерева, расформирование;
#   2. tools     — скорость встроенных инструментов через их API-эквиваленты
#                  (черчение, Push/Pull, Move, Rotate, Scale, Follow Me,
#                  Intersect, Paint Bucket, Zoom Extents; Offset и Solid
#                  Tools Ruby-API не имеют — помечено в отчёте);
#   3. viewport  — FPS вьюпорта на тяжёлой модели (компоненты + полигоны),
#                  режимы static/orbit;
#   4. animation — волна из кубиков 100×100×100 мм: бегущая диагональная
#                  волна пакетами Entities#transform_entities + полный
#                  оборот камеры (WaveTool);
#   5. storage   — файл ~130 МБ: кусковая сборка (уникальная геометрия +
#                  шумовые PNG-текстуры), калибровка размера, сохранение ×2
#                  и открытие с МБ/с.
#
# Набор ОДИН, без профилей и переопределений: полный прогон ~1 минута.
#
# Один и тот же план исполняется двумя способами:
#   • из меню/диалога — секвенсор на UI.start_timer (sequencer.rb): UI не
#     блокируется, FPS-метр получает честные кадры;
#   • через мост — пошагово отдельными eval (command.rb), между :fps/:wave
#     и сбором результата клиент выдерживает паузу сам.
#
# Сцена живёт внутри одной undo-операции: start_operation → build → тесты →
# clear! + abort_operation (проверенный паттерн). Модель пользователя после
# прогона возвращается к исходному состоянию, undo-стек не засоряется.
# Тест файла открывает собранный .skp в отдельной вкладке и закрывает его
# (паттерн DOC-тестов 0.2–0.3: смена модели только вне открытой операции).
#
# Замеры: только Process.clock_gettime(CLOCK_MONOTONIC); повтор count раз;
# статистика median/min/max + p95 (n>=10); GC.start между тестами. Каждый
# результат несёт контракт теста (schemas/result-schema-v1.json): id,
# test_version, категория, статус passed/failed/cancelled/skipped, параметры,
# валидация и диагностика. Ошибка теста не роняет прогон.
#
# Отмена: Runner.cancel! поднимает флаг; между повторами, порциями и шагами
# выполняющий код бросает Cancelled — результат получает статус cancelled,
# отчёт всё равно сохраняется. Сохранение/открытие файла — атомарные вызовы
# ядра, на их время UI кратко блокируется (отмечено в параметрах теста и
# предупреждении набора).
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Runner
    # Версия НАБОРА тестов: меняется при изменении состава/методики
    # (сравнение прогонов с разными suite-версиями помечается несовместимым).
    # 5 — набор ОДИН, без профилей и переопределений: параметры small с целью
    #     файла 130 МБ вместо 500 — полный прогон укладывается ~в минуту
    #     (500 МБ давали ~2 мин только на генерацию текстур). Прогоны v4
    #     несравнимы с v5 (сравнение пометит по test_suite_version).
    # 4 — полная смена набора под ТЗ от 2026-10-28: удалены RUBY/API-xx/
    #     сцены nested/grid/textured/DOC (малый файл)/fps_grid_*; новые
    #     категории modeling/tools/viewport/animation/storage (волна,
    #     файл ~500 МБ). Лимит компонентных сцен ≤10 тыс. инстансов —
    #     урок зависания SU2027 на 80 тыс. (suite v3).
    SUITE_VERSION = '5'
    # Версия конкретного теста: менять при изменении его измеряемой операции.
    TEST_VERSION = '1'

    # Категории таксономии ТЗ; group в результате = категория.
    GROUP_TITLES = {
      'modeling' => '1. Моделирование: сложная модель (эмуляция пользователя)',
      'tools' => '2. Инструменты SketchUp (API-эквиваленты)',
      'viewport' => '3. Вьюпорт: FPS на тяжёлой модели',
      'animation' => '4. Анимация: волна из кубиков 100×100 мм',
      'storage' => '5. Файл: сохранение и загрузка'
    }.freeze

    class Cancelled < StandardError
      def initialize(msg = 'прогон отменён пользователем')
        super
      end
    end

    # Активная модель сменилась посреди прогона (пользователь открыл/переключил
    # вкладку). Продолжать нельзя: очистка чужой модели недопустима.
    class ModelChanged < StandardError
      def initialize(msg = 'активная модель изменилась посреди прогона')
        super
      end
    end

    # Единый набор нагрузки (профилей нет): параметры пяти категорий,
    # полный прогон ~1 минута. Параметры сцен записываются в отчёт
    # (meta.params + параметры каждого теста).
    #   diverse: grid² сборок × leaves листьев = всего инстансов
    #            (лимит ≤10 000 — зависание SU2027 на 80 000);
    #   poly:    n² цилиндров по segments сегментов ≈ n²×(2s+2) треугольников;
    #   wave:    grid² кубов 100×100×100 мм, волна wave_s секунд;
    #   tools:   масштабы фикстур тестов инструментов;
    #   storage: уникальных тел + шумовые текстуры 4096² до цели target_mb
    #            (130 МБ: 3 текстуры по ~48 МБ; при 500 МБ генерация текстур
    #            одна занимала ~2 минуты).
    SUITE = {
      'targets' => { 'instances' => 1_024, 'triangles' => 173_000, 'file_mb' => 130 },
      'diverse' => { 'grid' => 16, 'leaves' => 4, 'leaf_defs' => 24, 'asm_defs' => 6 },
      'poly' => { 'n' => 40, 'segments' => 36 },
      'wave' => { 'grid' => 36 },
      'tools' => { 'draw' => 240, 'pushpull' => 24, 'inst' => 240,
                   'followme' => 8, 'intersect' => 16, 'paint' => 240 },
      'storage' => { 'boxes' => 1_200, 'tex_size' => 4_096, 'max_tex' => 24 },
      'target_mb' => 130,
      'fps_s' => 2.0, 'iters' => 3, 'wave_s' => 8.0
    }.freeze

    # Имя «профиля» в отчётах (один набор — одно имя; сравнение прогонов
    # и имя baseline-файла завязаны на него).
    SUITE_PROFILE = 'suite'

    SUITE_NOTE = 'тест файла ~130 МБ: генерация текстур и сохранение занимают ' \
                 'большую часть минуты прогона, нужно ~0,5 ГБ свободного места; ' \
                 'во время сохранения/открытия UI кратко блокируется'.freeze

    SUITE_WARNING = "Полный прогон занимает ~1 минуту. #{SUITE_NOTE}.".freeze

    class << self
      attr_reader :tool

      # -- отмена ----------------------------------------------------------------

      def cancel!
        @cancel_requested = true
        log_line('получен запрос отмены')
        true
      end

      def cancelled?
        @cancel_requested == true
      end

      # -- параметры набора ---------------------------------------------------------

      def suite_params
        deep_copy(SUITE).merge('profile' => SUITE_PROFILE)
      end

      # -- план прогона --------------------------------------------------------------

      def steps
        suite_params # копия — заодно прогрев Marshal (валидация константы)
        [
          { 'kind' => 'begin', 'label' => 'Инициализация' },
          { 'kind' => 'scene', 'scene' => 'diverse', 'category' => 'modeling',
            'label' => 'Моделирование: сборка сложной модели + правка/обход/расформирование' },
          { 'kind' => 'fps', 'id' => 'fps_components_static', 'mode' => 'static', 'category' => 'viewport',
            'name' => 'FPS: компоненты — статичный вид' },
          { 'kind' => 'fps', 'id' => 'fps_components_orbit', 'mode' => 'orbit', 'category' => 'viewport',
            'name' => 'FPS: компоненты — орбита' },
          { 'kind' => 'scene', 'scene' => 'poly', 'category' => 'viewport',
            'label' => 'Сцена полигональной нагрузки (сетка цилиндров)' },
          { 'kind' => 'fps', 'id' => 'fps_poly_static', 'mode' => 'static', 'category' => 'viewport',
            'name' => 'FPS: полигоны — статичный вид' },
          { 'kind' => 'fps', 'id' => 'fps_poly_orbit', 'mode' => 'orbit', 'category' => 'viewport',
            'name' => 'FPS: полигоны — орбита' },
          { 'kind' => 'scene', 'scene' => 'tools', 'category' => 'tools',
            'label' => 'Инструменты: черчение, push/pull, перемещение, поворот, масштаб, follow me, пересечение, окраска, zoom' },
          { 'kind' => 'scene', 'scene' => 'wave', 'category' => 'animation',
            'label' => 'Волна: построение полотна кубов 100×100 мм' },
          # Переключение страниц (Pages#selected_page=) автоматизировано НЕ будет:
          # применение страницы внутри открытой undo-операции фиксирует
          # транзакцию ядра, и последующий abort уже не откатывает контент
          # (инцидент 2026-10-28, SU2027). Ручной сценарий.
          { 'kind' => 'wave', 'id' => 'wave_animation', 'category' => 'animation',
            'name' => 'Волна: анимация + полный оборот камеры (FPS)' },
          { 'kind' => 'scene', 'scene' => 'storage', 'category' => 'storage',
            'label' => 'Файл: сборка модели ~130 МБ (геометрия + текстуры), сохранение ×2' },
          { 'kind' => 'storage_open', 'category' => 'storage', 'label' => 'Файл: открытие ~130 МБ' },
          { 'kind' => 'finish', 'label' => 'Отчёт' }
        ]
      end

      # Краткое описание плана для UI (без исполнения).
      def plan_preview
        {
          'profile' => SUITE_PROFILE,
          'params' => suite_params,
          'warning' => SUITE_WARNING,
          'steps' => steps.map do |s|
            { 'kind' => s['kind'], 'label' => s['label'] || s['name'], 'category' => s['category'] }
          end
        }
      end

      # -- исполнение шагов ------------------------------------------------------------

      def perform(step)
        case step['kind']
        when 'begin'        then begin_run
        when 'scene'        then open_scene(step['scene'])
        when 'fps'          then fps_start(step)
        when 'wave'         then wave_start(step)
        when 'storage_open' then storage_open_tests
        when 'finish'       then finish_run
        else "неизвестный шаг: #{step['kind']}"
        end
      ensure
        # Шаги, трогающие модель, обязаны остаться на модели прогона.
        # storage_open сам переключает модели (тест файла) и охраняется
        # сравнением путей внутри тиков.
        guard_model! if %w[scene fps wave].include?(step['kind'])
      end

      def begin_run
        params = suite_params
        model = Sketchup.active_model
        raise 'нет активной модели' if model.nil?

        close_scene # страховка: не должно быть висящей операции
        @cancel_requested = false
        @run_model = model
        @baseline_entities = model.entities.size
        @state = {
          'profile' => SUITE_PROFILE,
          'params' => params,
          'meta' => Environment.context(SUITE_PROFILE, params),
          'results' => [],
          'scene' => nil,
          'scene_info' => nil,
          'log' => []
        }
        log_line("прогон начат (набор v#{SUITE_VERSION}, ~1 минута)")
        begin
          File.delete(File.join(PngGen.temp_root, 'run_heartbeat.log'))
        rescue StandardError
          nil
        end
        'ok'
      end

      # Защита: каждый шаг и каждая очистка обязаны работать с той моделью,
      # на которой прогон был начат. Вне активного прогона guard не действует
      # (иначе «хвост» @run_model ломал бы всё после аварийного стопа).
      def guard_model!
        return if @state.nil? || @run_model.nil?
        return if Sketchup.active_model.equal?(@run_model)

        raise ModelChanged
      end

      # Полный сброс состояния прогона (аварийные пути: смена модели и т.п.).
      def abort_run!
        fps_stop_tool
        @state = nil
        @scene_state = nil
        @run_model = nil
        @baseline_entities = nil
        @cancel_requested = false
        nil
      end

      # -- кусковой движок (тяжёлая работа не блокирует UI надолго) ---------------
      #
      # Задача = последовательность ФАЗ; фаза = единицы работы [from, to),
      # выполняемые порциями ~CHUNK_TARGET_S секунд за тик. Между тиками
      # UI-поток свободен: работает отмена, клики, панель получает прогресс.
      # Тайминг — только длительности порций (простои между тиками не считаются),
      # поэтому методика замера не меняется. Фаза:
      #   'timed'    — копить ли длительности порций в task['times'];
      #   'total'    — число единиц;
      #   'batch'    — стартовый размер порции (далее адаптируется);
      #   'work'     — ->(from, to, ctx) { };
      #   'on_done'  — ->(ctx) { } после фазы (вне тайминга);
      #   'on_finish'= ->(times, phases) { } после последней фазы.

      CHUNK_TARGET_S = 1.0

      def task_tick(task)
        guard_model!
        raise Cancelled if cancelled?

        ph = task['phases'][task['pi']]
        if task['batch'].nil?
          task['batch'] = [ph['batch'] || ph['total'], ph['total']].min
          task['done'] = 0
        end
        from = task['done']
        to = [from + task['batch'], ph['total']].min
        t0 = Dn1supBenchmark.monotonic
        ph['work'].call(from, to, task['ctx'])
        dt = Dn1supBenchmark.monotonic - t0
        task['times'] << dt if ph['timed']
        ph['sums'] = ph['sums'].to_f + dt if ph['timed']
        task['done'] = to
        if dt.positive? && to < ph['total']
          nb = (task['batch'] * (CHUNK_TARGET_S / dt)).round
          task['batch'] = nb.clamp(1, ph['total'])
        end
        if task['done'] >= ph['total']
          ph['on_done']&.call(task['ctx'])
          task['pi'] += 1
          task['done'] = 0
          task['batch'] = nil
          if task['pi'] >= task['phases'].size
            task['on_finish'].call(task['times'], task['phases'], task['ctx'])
            return :done
          end
        end
        :in_progress
      end

      # Синхронное выполнение задачи (тесты/мост): крутит тики до конца.
      def task_drain(task)
        loop { return :done if task_tick(task) == :done }
      end

      # Прогресс текущей кусочной работы (для событий панели).
      def task_progress
        st = @scene_state
        return { 'done' => 0, 'total' => 0 } if st.nil? || st['task'].nil?

        t = st['task']
        ph = t['phases'][t['pi']] || {}
        { 'done' => t['done'], 'total' => ph['total'].to_i,
          'phase' => t['pi'] + 1, 'phases' => t['phases'].size }
      end

      def make_task(phases, on_finish)
        { 'phases' => phases, 'pi' => 0, 'done' => 0, 'batch' => nil,
          'ctx' => {}, 'times' => [], 'on_finish' => on_finish }
      end

      # Вставить работы в ГОЛОВУ очереди сцены (в порядке перечисления) —
      # для калибровочных цепочек storage, порождающих работы по ходу.
      # unshift(*jobs) сам ставит их в начало в естественном порядке.
      def queue_front(st, *jobs)
        st['jobs'].unshift(*jobs)
      end

      def open_scene(name)
        guard_model!
        st = @scene_state
        if st.nil?
          close_scene
          model = Sketchup.active_model
          raise 'нет активной модели' if model.nil?

          model.start_operation("DN1Sup Benchmark: #{name}", true)
          @state['scene'] = name
          @scene_state = { 'name' => name, 'jobs' => [], 'result' => nil }
          scene_plan(name, model)
        end
        scene_tick
      end

      # Очередь работ сцены: [:sync, callable] — мгновенная работа,
      # [:task, task] — кусочная (см. task_tick). Тик возвращает :in_progress,
      # пока у сцены есть работа — UI-поток между тиками свободен.
      def scene_tick
        st = @scene_state
        loop do
          if st['task']
            return :in_progress if task_tick(st['task']) == :in_progress

            st['task'] = nil # задача завершена — берём следующую работу
          end
          job = st['jobs'].shift
          if job.nil?
            GC.start
            @scene_state = nil
            return st['result']
          end
          if job[0] == :sync
            job[1].call
          else
            st['task'] = job[1]
            return :in_progress if task_tick(st['task']) == :in_progress

            st['task'] = nil
          end
        end
      end

      # План работ сцены: построение (кусками для тяжёлых сцен) + тесты.
      def scene_plan(name, model)
        st = @scene_state
        p = @state['params']
        case name
        when 'diverse' then plan_diverse(st, model, p)
        when 'poly'    then plan_poly(st, model, p)
        when 'tools'   then plan_tools(st, model, p)
        when 'wave'    then plan_wave(st, model, p)
        when 'storage' then plan_storage(st, model, p)
        else raise ArgumentError, "неизвестная сцена: #{name}"
        end
      end

      def close_scene
        return if @state.nil?
        return if @state['scene'].nil?

        # Очистка допустима ТОЛЬКО на модели прогона: clear! на чужой модели
        # уничтожил бы контент пользователя.
        if @run_model && !Sketchup.active_model.equal?(@run_model)
          log_line('close_scene: активная модель сменилась — очистка НЕ выполняется')
          @state['scene'] = nil
          @state['scene_info'] = nil
          @scene_state = nil
          return nil
        end

        model = Sketchup.active_model
        leave_edit_context(model)
        begin
          model.entities.clear!
          model.abort_operation
        rescue StandardError => e
          log_line("close_scene: #{e.class}: #{e.message}")
        end
        # Контроль отката: число сущностей обязано вернуться к базовому.
        now = model.entities.size rescue nil
        if @baseline_entities && now && now != @baseline_entities
          log_line("ВНИМАНИЕ: после отката сущностей #{now}, было #{@baseline_entities} — " \
                   'модель изменена, откат неполный')
        end
        @state['scene'] = nil
        @state['scene_info'] = nil
        @scene_state = nil
        GC.start
        nil
      end

      # ==========================================================================
      # 1. MODELING — эмуляция моделирования пользователя
      # ==========================================================================

      def plan_diverse(st, model, p)
        dp = p['diverse']
        grid = dp['grid']
        leaves = dp['leaves']
        leaf_defs_n = dp['leaf_defs']
        asm_defs_n = dp['asm_defs']
        total_instances = grid * grid * leaves

        build = make_task(
          [
            { 'timed' => true, 'total' => leaf_defs_n, 'batch' => 8,
              'work' => lambda { |from, to, ctx|
                (ctx['leaf_defs'] ||= []).concat(
                  from.upto(to - 1).map { |i| Scenes.diverse_leaf_def(model, i) }
                )
              } },
            { 'timed' => true, 'total' => asm_defs_n, 'batch' => 4,
              'work' => lambda { |from, to, ctx|
                (ctx['asm_defs'] ||= []).concat(
                  from.upto(to - 1).map { |j| Scenes.diverse_asm_def(model, ctx['leaf_defs'], j, leaves) }
                )
              } },
            { 'timed' => true, 'total' => grid * grid, 'batch' => 128,
              'work' => lambda { |from, to, ctx|
                (ctx['instances'] ||= []).concat(
                  from.upto(to - 1).map { |i| Scenes.diverse_top_instance(model, ctx['asm_defs'], grid, i) }
                )
              } }
          ],
          lambda { |_times, phs, ctx|
            total = phs.select { |ph| ph['timed'] }.sum { |ph| ph['sums'].to_f }
            @state['scene_info'] = {
              'instances' => ctx['instances'], 'leaf_defs' => ctx['leaf_defs'],
              'grid' => grid, 'leaves' => leaves, 'entities' => total_instances
            }
            GC.start
            add_result('modeling', 'model_build',
                       "Сборка сложной модели: #{leaf_defs_n} уникальных компонентов, " \
                       "#{asm_defs_n} сборок, сетка #{grid}×#{grid} (#{total_instances} инстансов)",
                       'ms', [total],
                       entities: total_instances, entities_created: total_instances,
                       ops: total_instances,
                       params: { 'leaf_definitions' => leaf_defs_n,
                                 'assembly_definitions' => asm_defs_n,
                                 'leaves_per_assembly' => leaves, 'grid' => grid,
                                 'instances_total' => total_instances,
                                 'content' => 'все листовые компоненты разные; сборки из разных наборов' },
                       status: 'passed')
            log_line("diverse: #{(total * 1000).round} мс, инстансов #{total_instances}")
          }
        )
        st['jobs'] << [:task, build]
        st['jobs'] << [:sync, -> {
          tests_modeling(model, p)
          st['result'] = "ok: diverse (#{total_instances} инстансов)"
        }]
      end

      def tests_modeling(model, p)
        info = @state['scene_info'] || {}
        iters = p['iters']
        leaf_defs = info['leaf_defs'] || []
        instances = (info['instances'] || []).select { |i| i.respond_to?(:valid?) && i.valid? }

        # Правка листового определения: добавить грань → вытянуть → стереть.
        # Все инстансы определения пересчитываются ядром.
        unless leaf_defs.empty?
          leaf = leaf_defs.first
          before = leaf.entities.size
          measure('modeling', 'model_edit_definition',
                  "Правка определения компонента (пересчёт всех инстансов)",
                  'ms', iters,
                  entities: instances.size, ops: 1,
                  params: { 'definition' => leaf.name,
                            'op' => 'add_face + pushpull ±30 мм + erase (цикл)',
                            'instances_sharing' => 'определение используется сборками по всей сетке' },
                  validate: proc { |sz| sz == before ? [] : ["сущностей определения #{sz} вместо #{before}"] }) do |i|
            face = leaf.entities.add_face([10.mm, 10.mm, 0], [50.mm, 10.mm, 0],
                                          [50.mm, 50.mm, 0], [10.mm, 50.mm, 0])
            # pushpull в минус схлопывает бокс и удаляет грань — проверяем.
            face.pushpull(i.even? ? 30.mm : -30.mm)
            leaf.entities.erase_entities([face]) if face.valid?
            leaf.entities.size
          end
        end

        # Обход дерева модели: рекурсивно, включая определения инстансов.
        measure('modeling', 'model_traverse', 'Обход дерева модели (группы + компоненты)',
                'ms', iters,
                entities: info['entities'], ops: info['entities'],
                params: { 'op' => 'рекурсивный обход entities; у инстансов — определения' },
                validate: proc { |c| c.to_i.positive? ? [] : ['обход вернул 0'] }) do |_i|
          traverse_count(model)
        end

        # Расформирование половины сборок верхнего уровня (один проход).
        k = instances.size / 2
        if k.positive?
          t0 = Dn1supBenchmark.monotonic
          instances.first(k).each(&:explode)
          dt = Dn1supBenchmark.monotonic - t0
          add_result('modeling', 'model_explode', "Расформирование сборок (#{k} шт. → группы)",
                     'ms', [dt], entities: k, ops: k,
                     params: { 'exploded' => k, 'op' => 'ComponentInstance#explode' },
                     status: 'passed')
          log_line("model_explode: #{(dt * 1000).round} мс")
        end
      end

      def traverse_count(model)
        total = 0
        stack = model.entities.to_a
        until stack.empty?
          e = stack.pop
          total += 1
          if e.is_a?(Sketchup::Group)
            stack.concat(e.entities.to_a)
          elsif e.is_a?(Sketchup::ComponentInstance)
            stack.concat(e.definition.entities.to_a)
          end
        end
        total
      end

      # ==========================================================================
      # 2. TOOLS — скорость встроенных инструментов (API-эквиваленты)
      # ==========================================================================
      # Нативные инструменты не имеют мышиного драйвера: тестируются API под
      # ними. Offset и Solid Tools Ruby-API не предоставляют — фиксируется в
      # отчёте (дисклеймер группы). Фикстуры строятся в своих группах, чтобы
      # не задевать содержимое модели пользователя.

      def plan_tools(st, model, p)
        st['jobs'] << [:sync, -> { test_tool_draw(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_pushpull(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_transforms(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_followme(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_intersect(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_paint(model, p) }]
        st['jobs'] << [:sync, -> { test_tool_zoom_extents(model, p) }]
        st['jobs'] << [:sync, -> { st['result'] = 'ok: tools (9 тестов)' }]
      end

      # Черчение: линии, прямоугольники, окружности, дуги — по per штук каждого.
      def test_tool_draw(model, p)
        per = (p['tools']['draw'] / 4.0).ceil
        measure_op('tools', 'tool_draw',
                   "Черчение: линии, прямоугольники, окружности, дуги (по #{per})",
                   'ms', p['iters'],
                   entities: per * 4, ops: per * 4,
                   params: { 'each_kind' => per, 'kinds' => 'add_line, add_face, add_circle(24), add_arc(12)',
                             'native_tools' => 'Line / Rectangle / Circle / Arc' },
                   setup: ->(_i) { [] },
                   check: proc { |created, _ctx|
                     created.count { |e| e.respond_to?(:valid?) && e.valid? } == created.size ? [] : ['часть сущностей невалидна']
                   },
                   cleanup: proc { |created, _ctx|
                     model.entities.erase_entities(created.select { |e| e.respond_to?(:valid?) && e.valid? })
                   }) do |created, _i|
          ents = model.entities
          per.times do |k|
            x = (k % 50) * 300.mm
            y = ((k / 50) % 50) * 300.mm
            created << ents.add_line([x, y, 0], [x + 200.mm, y, 0])
            face = ents.add_face([x, y + 300.mm, 0], [x + 200.mm, y + 300.mm, 0],
                                 [x + 200.mm, y + 500.mm, 0], [x, y + 500.mm, 0])
            created << face
            created.concat(face.edges)
            circle = ents.add_circle([x + 100.mm, y + 700.mm, 0], [0, 0, 1], 80.mm, 24)
            created.concat(Scenes.curve_edges(circle))
            arc = ents.add_arc([x + 300.mm, y + 700.mm, 0], [1, 0, 0], [0, 0, 1], 80.mm, 0, Math::PI, 12)
            created.concat(Scenes.curve_edges(arc))
          end
          created
        end
      end

      # Push/Pull: батч граней +40/−40 мм (ссылки на грани переживают вытягивание
      # внутри группы, поэтому батч собирается заново на каждой итерации).
      def test_tool_pushpull(model, p)
        n = p['tools']['pushpull']
        g = model.entities.add_group
        n.times do |k|
          x = (k % 20) * 300.mm
          y = ((k / 20) % 20) * 300.mm
          g.entities.add_face([x, y, 0], [x + 200.mm, y, 0], [x + 200.mm, y + 200.mm, 0], [x, y + 200.mm, 0])
        end
        measure('tools', 'tool_pushpull', "Push/Pull батча граней (#{n} шт.)",
                'ms', p['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'pushpull ±40 мм', 'native_tool' => 'Push/Pull' }) do |i|
          h = i.even? ? 40.mm : -40.mm
          g.entities.grep(Sketchup::Face).first(n).each { |f| f.pushpull(h) }
        end
      end

      # Move / Rotate / Scale: пакетные трансформации инстансов одним вызовом
      # Entities#transform_entities (фигура возвращается на место каждую
      # нечётную итерацию — чётные повторы восстанавливают исходное положение).
      def test_tool_transforms(model, p)
        n = p['tools']['inst']
        g = model.entities.add_group
        defn = model.definitions.add('dn1_tool_box')
        face = defn.entities.add_face([0, 0, 0], [100.mm, 0, 0], [100.mm, 100.mm, 0], [0, 100.mm, 0])
        face.pushpull(80.mm)
        insts = n.times.map do |k|
          x = (k % 40) * 200.mm
          y = ((k / 40) % 40) * 200.mm
          g.entities.add_instance(defn, Geom::Transformation.new([x, y, 0]))
        end

        measure('tools', 'tool_move', "Перемещение батча инстансов (#{n} шт.)",
                'ms', p['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'transform_entities: сдвиг ±50 мм',
                          'native_tool' => 'Move' }) do |i|
          dx = i.even? ? 50.mm : -50.mm
          g.entities.transform_entities(Geom::Transformation.translation([dx, 0, 0]), insts)
        end

        measure('tools', 'tool_rotate', "Поворот батча инстансов (#{n} шт.)",
                'ms', p['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'transform_entities: поворот ±10° вокруг Z',
                          'native_tool' => 'Rotate' }) do |i|
          ang = i.even? ? 10.degrees : -10.degrees
          g.entities.transform_entities(Geom::Transformation.rotation([0, 0, 0], [0, 0, 1], ang), insts)
        end

        measure('tools', 'tool_scale', "Масштаб батча инстансов (#{n} шт.)",
                'ms', p['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'transform_entities: масштаб ×1.05 / ÷1.05',
                          'native_tool' => 'Scale' }) do |i|
          s = i.even? ? 1.05 : 1.0 / 1.05
          g.entities.transform_entities(Geom::Transformation.scaling(ORIGIN, s), insts)
        end
      end

      # Follow Me: профиль следует по ломаной дуге (Face#followme).
      def test_tool_followme(model, p)
        n = p['tools']['followme']
        measure_op('tools', 'tool_followme', "Follow Me: профиль по дуге (#{n} путей)",
                   'ms', p['iters'],
                   entities: n * 4, ops: n,
                   params: { 'paths' => n, 'path' => 'четверть окружности из 12 отрезков',
                             'profile' => 'квадрат 60×60 мм', 'native_tool' => 'Follow Me' },
                   setup: proc { |i|
                     group = model.entities.add_group
                     edges = []
                     pts = 13.times.map do |k|
                       ang = k * Math::PI / 24
                       [(Math.cos(ang) * 500.mm), (Math.sin(ang) * 500.mm), ((i + 1) * 10_000).mm]
                     end
                     pts.each_cons(2) { |a, b| edges << group.entities.add_line(a, b) }
                     face = group.entities.add_face([0, 0, 10_000.mm], [0, 60.mm, 10_000.mm],
                                                    [0, 60.mm, 10_060.mm], [0, 0, 10_060.mm])
                     { 'group' => group, 'face' => face, 'edges' => edges,
                       'before' => group.entities.size }
                   },
                   check: proc { |_res, ctx|
                     ctx['group'].entities.size > ctx['before'] ? [] : ['тело не построено']
                   },
                   cleanup: proc { |_res, ctx|
                     model.entities.erase_entities([ctx['group']]) if ctx['group'].valid?
                   }) do |ctx, _i|
          ctx['face'].followme(ctx['edges'])
        end
      end

      # Intersect Faces: две сетки боксов, пересечение в контексте группы.
      def test_tool_intersect(model, p)
        n = p['tools']['intersect']
        identity = Geom::Transformation.new
        measure_op('tools', 'tool_intersect', "Intersect Faces: две сетки боксов (по #{n})",
                   'ms', p['iters'],
                   entities: n * 2, ops: n * 2,
                   params: { 'boxes_each' => n, 'op' => 'Entities#intersect_with(recurse=true)',
                             'native_tool' => 'Intersect Faces' },
                   setup: proc { |i|
                     group = model.entities.add_group
                     a = group.entities.add_group
                     b = group.entities.add_group
                     [a, b].each_with_index do |gr, gi|
                       n.times do |k|
                         x = (k % 8) * 300.mm + (gi * 150).mm
                         y = ((k / 8) % 8) * 300.mm + (gi * 150).mm
                         z = ((i + 1) * 20_000).mm
                         face = gr.entities.add_face([x, y, z], [x + 200.mm, y, z],
                                                     [x + 200.mm, y + 200.mm, z], [x, y + 200.mm, z])
                         face.pushpull(200.mm)
                       end
                     end
                     [group, a, b]
                   },
                   check: proc { |edges, _ctx|
                     edges.is_a?(Array) && !edges.empty? ? [] : ['рёбер пересечения не создано']
                   },
                   cleanup: proc { |(group, _a, _b), _ctx|
                     model.entities.erase_entities([group]) if group.valid?
                   }) do |(group, a, b), _i|
          group.entities.intersect_with(true, identity, a.entities, identity, false, b.entities.to_a)
        end
      end

      # Paint Bucket: назначение цветных материалов батчу граней.
      def test_tool_paint(model, p)
        n = p['tools']['paint']
        g = model.entities.add_group
        n.times do |k|
          x = (k % 40) * 200.mm
          y = ((k / 40) % 40) * 200.mm
          g.entities.add_face([x, y, 0], [x + 150.mm, y, 0], [x + 150.mm, y + 150.mm, 0], [x, y + 150.mm, 0])
        end
        measure('tools', 'tool_paint', "Paint Bucket: окраска батча граней (#{n} шт.)",
                'ms', p['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'новый цветной материал + назначение граням',
                          'native_tool' => 'Paint Bucket' }) do |i|
          cval = (i * 47) % 255
          mat = model.materials.add("dn1_paint_#{i}")
          mat.color = Sketchup::Color.new(cval, (cval * 2) % 255, 255 - cval)
          g.entities.grep(Sketchup::Face).first(n).each { |f| f.material = mat }
        end
      end

      def test_tool_zoom_extents(model, _p)
        view = model.active_view
        measure('tools', 'tool_zoom_extents', 'Zoom Extents на текущей сцене',
                'ms', @state['params']['iters'],
                params: { 'op' => 'view.zoom_extents',
                          'note' => 'единичный вызов вида — не кускуется, может кратко занять UI' }) do |_i|
          view.zoom_extents
        end
      end

      # ==========================================================================
      # 3. VIEWPORT — FPS на тяжёлой модели (FpsTool)
      # ==========================================================================

      def plan_poly(st, model, p)
        pp = p['poly']
        n = pp['n']
        segments = pp['segments']
        st['jobs'] << [:sync, -> {
          @state['scene_info'] = { 'n' => n, 'segments' => segments,
                                   'defn' => Scenes.poly_cylinder_def(model, segments) }
          log_line("poly: определение цилиндра (#{segments} сегм.) готово")
        }]
        build = make_task(
          [{ 'timed' => false, 'total' => n * n, 'batch' => 256,
             'work' => lambda { |from, to, _ctx|
               defn = @state['scene_info']['defn']
               from.upto(to - 1) { |i| Scenes.poly_instance(model, defn, n, i) }
             } }],
          lambda { |_t, _ph, _ctx| log_line("poly: #{n * n} инстансов цилиндров") }
        )
        st['jobs'] << [:task, build]
        st['jobs'] << [:sync, -> { st['result'] = "ok: poly (#{n * n} цилиндров)" }]
      end

      def fps_start(step)
        return 'нет активного прогона' if @state.nil?
        return 'FPS только на открытой сцене' if @state['scene'].nil?

        fps_stop_tool # страховка от забытого инструмента
        view = Sketchup.active_model.active_view
        view.zoom_extents
        @tool = FpsTool.new(@state['params']['fps_s'], step['mode'])
        @fps_step = step
        Sketchup.active_model.select_tool(@tool)
        "started: #{step['id']} (#{step['mode']}, #{@state['params']['fps_s']}s)"
      end

      def fps_ready?
        !@tool.nil? && !@tool.result.nil?
      end

      # Лимит ожидания асинхронного шага (FPS/волна) для опроса секвенсора:
      # с запасом относительно длительности волны.
      def async_step_limit
        return 30.0 if @state.nil?

        (@state['params']['wave_s'].to_f * 3.0).clamp(30.0, 180.0)
      end

      def fps_collect
        return 'нет активного FPS-замера' if @tool.nil?

        step = @fps_step
        result = @tool.result || @tool.stop_now
        fps_stop_tool
        group = step['kind'] == 'wave' ? 'animation' : 'viewport'
        if cancelled?
          add_skipped(group, step['id'], step['name'], 'отменено пользователем', status: 'cancelled')
          return 'cancelled'
        end
        if result.nil? || result['frames'].to_i.zero?
          add_result(group, step['id'], step['name'], 'fps', [],
                     status: 'failed',
                     diagnostics: [{ 'class' => 'RuntimeError', 'message' => 'кадры не отрисовались', 'backtrace' => [] }])
          log_line("#{step['id']}: кадры не отрисовались")
          return 'failed'
        end
        if step['kind'] == 'wave'
          collect_wave(result)
        else
          collect_fps(step, result)
        end
      end

      def collect_fps(step, result)
        add_result('viewport', step['id'], step['name'], 'fps',
                   [result['fps']], higher: true,
                   entities: fps_scene_entities,
                   params: fps_scene_params.merge(
                     'duration_s' => result['elapsed_s'],
                     'source' => 'счётчик кадров Tool#draw + view.invalidate (Ruby-сторона, не GPU-счётчик)',
                     'window' => 'окно SketchUp должно быть видимым: свёрнутое/перекрытое окно не отрисовывает кадры'
                   ),
                   extra: { 'frames' => result['frames'], 'elapsed_s' => result['elapsed_s'], 'mode' => result['mode'] })
        log_line("#{step['id']}: #{result['fps']} fps (#{result['frames']} кадров)")
        "ok: #{result['fps']} fps"
      end

      def fps_scene_entities
        info = @state['scene_info'] || {}
        case @state['scene']
        when 'diverse'
          (info['instances'] || []).count { |i| i.respond_to?(:valid?) && i.valid? }
        when 'poly' then info['n'].to_i**2
        else nil
        end
      end

      def fps_scene_params
        info = @state['scene_info'] || {}
        case @state['scene']
        when 'diverse'
          { 'scene' => 'уникальные компоненты в вложенных сборках',
            'grid' => info['grid'], 'leaves_per_assembly' => info['leaves'] }
        when 'poly'
          n = info['n'].to_i
          seg = info['segments'].to_i
          { 'scene' => 'сетка цилиндров (полигональная нагрузка)',
            'segments' => seg, 'triangles' => n * n * (2 * seg + 2) }
        else
          { 'scene' => @state['scene'].to_s }
        end
      end

      def fps_stop_tool
        return if @tool.nil?

        begin
          Sketchup.active_model.select_tool(nil)
        rescue StandardError
          nil
        end
        @tool = nil
        nil
      end

      # ==========================================================================
      # 4. ANIMATION — волна из кубиков 100×100×100 мм (WaveTool)
      # ==========================================================================

      def plan_wave(st, model, p)
        grid = p['wave']['grid']
        st['jobs'] << [:sync, -> {
          @state['scene_info'] = { 'defn' => Scenes.wave_cube_def(model), 'grid' => grid,
                                   'instances' => [], 'positions' => [] }
        }]
        build = make_task(
          [{ 'timed' => true, 'total' => grid * grid, 'batch' => 128,
             'work' => lambda { |from, to, _ctx|
               info = @state['scene_info']
               from.upto(to - 1) do |i|
                 inst, x, y = Scenes.wave_cube(model, info['defn'], grid, i)
                 info['instances'] << inst
                 info['positions'] << [x, y]
               end
             } }],
          lambda { |_times, phs, _ctx|
            info = @state['scene_info']
            dt = phs[0]['sums'].to_f
            add_result('animation', 'wave_build',
                       "Построение полотна: #{grid}×#{grid} кубов 100×100×100 мм",
                       'ms', [dt],
                       entities: grid * grid, entities_created: grid * grid, ops: grid * grid,
                       params: { 'grid' => grid, 'cube_mm' => 100,
                                 'note' => 'справочное время сборки, в балл не входит' },
                       status: 'passed')
            log_line("wave: полотно #{grid}×#{grid} за #{(dt * 1000).round} мс")
          }
        )
        st['jobs'] << [:task, build]
        st['jobs'] << [:sync, -> { st['result'] = "ok: wave (#{grid * grid} кубов)" }]
      end

      def wave_start(step)
        return 'нет активного прогона' if @state.nil?
        return 'волна требует открытой сцены wave' if @state['scene'] != 'wave'

        info = @state['scene_info'] || {}
        return 'полотно волны не построено' if (info['instances'] || []).empty?

        fps_stop_tool
        view = Sketchup.active_model.active_view
        view.zoom_extents
        wave_s = @state['params']['wave_s']
        @tool = WaveTool.new(wave_s, info['instances'], info['positions'])
        @fps_step = step
        Sketchup.active_model.select_tool(@tool)
        "started: волна #{info['grid']}×#{info['grid']} (#{wave_s}s)"
      end

      def collect_wave(result)
        info = @state['scene_info'] || {}
        grid = info['grid'].to_i
        cubes = grid * grid
        add_result('animation', 'fps_wave_orbit', 'Волна + вращение камеры: FPS', 'fps',
                   [result['fps']], higher: true, entities: cubes,
                   params: { 'grid' => grid, 'cubes' => cubes, 'cube_mm' => 100,
                             'amplitude_mm' => WaveTool::AMPLITUDE_MM,
                             'wavelength_cells' => WaveTool::WAVELENGTH_CELLS,
                             'period_s' => WaveTool::PERIOD_S,
                             'duration_s' => result['elapsed_s'],
                             'wave' => 'z = A·sin(2π(x+y)/λ − 2πt/T), диагональная бегущая',
                             'camera' => 'полный оборот 360° вокруг полотна',
                             'source' => 'счётчик кадров Tool#draw + view.invalidate (Ruby-сторона, не GPU-счётчик)' },
                   extra: { 'frames' => result['frames'], 'elapsed_s' => result['elapsed_s'] })
        updates = result['update_ms'] || []
        unless updates.empty?
          add_result('animation', 'wave_update_ms',
                     "Волна: пакетное обновление геометрии (#{cubes} кубов, ~#{WaveTool::TIMER_HZ.round} Гц)",
                     'ms', updates.map { |ms| ms / 1000.0 },
                     entities: cubes, ops: cubes,
                     params: { 'cubes' => cubes, 'timer_hz' => WaveTool::TIMER_HZ,
                               'op' => 'дельты z по корзинам 1 мм → Entities#transform_entities',
                               'samples' => updates.size })
        end
        log_line("волна: #{result['fps']} fps, обновлений #{updates.size}")
        "ok: волна #{result['fps']} fps"
      end

      # ==========================================================================
      # 5. STORAGE — файл ~130 МБ: сборка, калибровка, сохранение ×2, открытие
      # ==========================================================================
      # Модель собирается в ОПРЕДЕЛЕНИЕ dn1_storage текущей модели (внутри
      # undo-операции сцены; без инстансов — вьюпорт не нагружается) и
      # выгружается ComponentDefinition#save_copy во временную папку: модель
      # пользователя не сохраняется и не перезаписывается. Размер добирается
      # шумовыми PNG-текстурами 4096² (материалы назначаются граням — без
      # назначения материал в файл не попадает). Тест открытия идёт ОТДЕЛЬНЫМ
      # шагом после close_scene: файл открывается в новой вкладке и
      # закрывается — смена модели только вне открытой операции (паттерн
      # DOC-тестов 0.2–0.3).

      def plan_storage(st, model, p)
        st['jobs'] << [:sync, -> { storage_setup(st, model, p) }]
        st['jobs'] << [:sync, -> { storage_calibration(st, model, p) }]
        st['jobs'] << [:sync, -> { storage_timed_saves(st, p) }]
        st['jobs'] << [:sync, -> {
          sg = st['storage']
          @state['scene_info'] = { 'path' => sg['path'], 'size' => sg['bytes'] }
          log_line("storage: сцена завершена, scene_info.path=" +
                   (sg['path'] ? File.basename(sg['path']) : 'nil'))
          st['result'] = "ok: storage (#{(sg['bytes'] / 1_048_576.0).round} МБ)"
        }]
      end

      def storage_setup(st, model, p)
        target_mb = p['target_mb'].to_f
        dir = PngGen.mkdir_p(File.join(PngGen.temp_root, 'storage'))
        # Уборка больших файлов прошлых прогонов (файл может остаться после
        # аварийного стопа — блокировка файловой системы мешает удалить его
        # сразу после открытия).
        Dir.glob(File.join(dir, 'big_*.skp')).each do |f|
          File.delete(f)
        rescue StandardError
          nil
        end
        path = File.join(dir, "big_#{Time.now.strftime('%Y%m%d-%H%M%S')}.skp")
        need = (target_mb * 1_048_576 * 2.2).round
        free = disk_free_bytes(dir)
        if free && free < need
          msg = "недостаточно места на диске: свободно #{(free / 1_048_576.0).round} МБ, " \
                "нужно ~#{(need / 1_048_576.0).round} МБ"
          log_line("storage: #{msg}")
          add_result('storage', 'storage_save', 'Сохранение файла ~130 МБ', 'ms', [],
                     status: 'failed',
                     params: { 'error' => msg }, diagnostics: [diag_hash(RuntimeError.new(msg))])
          add_result('storage', 'storage_open', 'Открытие файла ~130 МБ', 'ms', [],
                     status: 'failed',
                     params: { 'error' => msg }, diagnostics: [diag_hash(RuntimeError.new(msg))])
          st['storage'] = { 'path' => nil, 'bytes' => 0 }
          st['jobs'].clear
          st['result'] = "пропущено: #{msg}"
          return
        end
        defn = model.definitions.add('dn1_storage')
        st['storage'] = { 'path' => path, 'defn' => defn, 'tex' => 0, 'bytes' => 0,
                          'mats' => [], 'faces' => nil }
        sp = p['storage']
        boxes = sp['boxes']
        log_line("storage: цель ~#{target_mb.round} МБ, коробок #{boxes}, " \
                 "текстуры до #{sp['max_tex']}×#{sp['tex_size']}²")
        geom = make_task(
          [{ 'timed' => true, 'total' => boxes, 'batch' => [boxes, 200].min,
             'work' => lambda { |from, to, _ctx|
               defn = st['storage']['defn']
               from.upto(to - 1) { |k| Scenes.storage_box(defn, k) }
             } }],
          lambda { |_times, phs, _ctx|
            dt = phs[0]['sums'].to_f
            sg = st['storage']
            sg['faces'] = sg['defn'].entities.grep(Sketchup::Face)
            add_result('storage', 'storage_build',
                       "Сборка модели: #{boxes} уникальных тел",
                       'ms', [dt], entities: sg['faces'].size, ops: boxes,
                       params: { 'boxes' => boxes, 'unique' => true,
                                 'note' => 'справочное время сборки, в балл не входит' },
                       status: 'passed')
            log_line("storage: геометрия #{(dt * 1000).round} мс")
          }
        )
        queue_front(st, [:task, geom])
      end

      # Калибровка размера: сохранение после геометрии; если файл меньше
      # 0.9×цели — пробная текстура (замер её вклада), затем добор пачкой.
      def storage_calibration(st, model, p)
        sg = st['storage']
        return if sg['path'].nil?

        target = (p['target_mb'] * 1_048_576).round
        sp = p['storage']
        sg['defn'].save_copy(sg['path'])
        sg['bytes'] = File.size(sg['path'])
        log_line("storage: геометрия дала #{mb_str(sg['bytes'])}")
        return if sg['bytes'] >= target * 0.9

        # Текстура + ПОСЛЕ неё проба размера (очередь атомарна: задача и
        # следующий за ней sync идут одной очередью в правильном порядке).
        push_texture_jobs(st, model, sp, 1, -> { storage_probe_result(st, model, p) })
      end

      def storage_probe_result(st, model, p)
        sg = st['storage']
        return if sg['path'].nil?

        target = (p['target_mb'] * 1_048_576).round
        sp = p['storage']
        storage_assign_materials(model, sg)
        sg['defn'].save_copy(sg['path'])
        size1 = File.size(sg['path'])
        per_tex = size1 - sg['bytes']
        sg['bytes'] = size1
        log_line("storage: +1 текстура = #{mb_str(per_tex)} → #{mb_str(size1)}")
        return if size1 >= target * 0.9 || per_tex <= 0

        more = (((target - size1).to_f / per_tex)).ceil
        more = [more, sp['max_tex'] - sg['tex']].min
        return unless more.positive?

        push_texture_jobs(st, model, sp, more, -> { storage_assign_materials(model, st['storage']) })
      end

      # Задача добавления count текстур: PNG генерируется КУСОЧНО (строки
      # порциями ~1 с, сжатие инкрементально; UI отвечает, отмена работает),
      # затем материал назначается граням (вне тайминга — это setup файла).
      # follow_sync — работа, встающая в очередь СРАЗУ ПОСЛЕ текстур.
      def push_texture_jobs(st, model, sp, count, follow_sync = nil)
        size = sp['tex_size']
        first = st['storage']['tex']
        phases = count.times.map do |j|
          idx = first + j
          { 'timed' => false, 'total' => size, 'batch' => 200,
            'work' => lambda { |from, to, ctx|
              w = ((ctx['writers'] ||= {})[idx] ||= PngGen::NoiseWriter.new(storage_tex_path(idx, size), size, idx))
              w.tick(from, to)
            },
            'on_done' => lambda { |ctx|
              w = ctx['writers'][idx]
              w.finish! unless w.cached?
              mat = model.materials.add("dn1_storage_tex_#{idx}")
              mat.texture = storage_tex_path(idx, size)
              st['storage']['mats'] << mat
            } }
        end
        task = make_task(phases, lambda { |_t, _ph, _ctx|
          st['storage']['tex'] += count
          log_line("storage: текстур готово #{st['storage']['tex']}")
        })
        jobs = [[:task, task]]
        jobs << [:sync, follow_sync] if follow_sync
        queue_front(st, *jobs)
      end

      def storage_tex_path(idx, size)
        File.join(PngGen.texture_dir, "noise_#{size}_#{idx}.png")
      end

      def storage_assign_materials(model, sg)
        mats = sg['mats']
        return if mats.empty?

        faces = sg['faces'] || sg['defn'].entities.grep(Sketchup::Face)
        return if faces.empty?

        faces.each_with_index { |f, k| f.material = mats[k % mats.size] }
      end

      def storage_timed_saves(st, p)
        sg = st['storage']
        return if sg['path'].nil?

        path = sg['path']
        times = []
        2.times do
          raise Cancelled if cancelled?

          t0 = Dn1supBenchmark.monotonic
          sg['defn'].save_copy(path)
          times << (Dn1supBenchmark.monotonic - t0)
          sg['bytes'] = File.size(path) if File.exist?(path)
        end
        med_s = median(times)
        mbps = med_s && med_s.positive? ? (sg['bytes'] / 1_048_576.0) / med_s : nil
        add_result('storage', 'storage_save',
                   "Сохранение файла #{(sg['bytes'] / 1_048_576.0).round} МБ (save ×2)",
                   'ms', times,
                   entities: sg['faces'] ? sg['faces'].size : nil, ops: 1,
                   file_size: sg['bytes'],
                   params: { 'target_mb' => @state['params']['target_mb'],
                             'boxes' => @state['params']['storage']['boxes'],
                             'textures' => sg['tex'],
                             'op' => 'ComponentDefinition#save_copy',
                             'path' => 'временная папка пользователя',
                             'cache' => 'файловый кэш ОС тёплый; «холодный» запуск не заявляется',
                             'note' => 'сохранение атомарно — UI кратко блокируется' },
                   extra: { 'mb_per_s' => mbps&.round(1),
                            'file_mb' => (sg['bytes'] / 1_048_576.0).round(1) })
        log_line("storage: сохранение #{mb_str(sg['bytes'])} за #{((med_s || 0) * 1000).round} мс")
      end

      # Открытие собранного файла (отдельный шаг): сцена уже закрыта, файл
      # открывается в новой вкладке, валидируется и закрывается без сохранения.
      # Sketchup.open_file на SU2024+ АСИНХРОНЕН В ЛЮБОЙ перегрузке: вызов
      # возвращается до завершения загрузки, активная модель меняется позже
      # (для файла ~144 МБ с текстурами — десятки секунд). Поэтому шаг работает
      # тиками: секвенсор опрашивает storage_open_tick повторяющимся таймером,
      # тайминг попытки — от вызова open_file до смены активной модели.
      OPEN_TIMEOUT_S = 300.0

      def storage_open_tests
        return 'нет активного прогона' if @state.nil?

        info = @state['scene_info'] || {}
        if info['path'].nil?
          return add_skipped('storage', 'storage_open', 'Открытие файла ~130 МБ',
                             cancelled? ? 'отменено пользователем' : 'файл не был собран',
                             status: cancelled? ? 'cancelled' : 'skipped')
        end

        if @storage_open.nil?
          close_scene # откат сборки: файл уже на диске
          model = Sketchup.active_model
          raise 'нет активной модели' if model.nil?

          @storage_open = {
            'orig' => model, 'path' => info['path'], 'size' => info['size'].to_i,
            'opens' => [], 'diag' => [], 'val' => [],
            'iters' => [@state['params']['iters'], 2].min,
            'i' => 0, 't0' => nil, 'waiting' => false, 'last_seen' => nil
          }
          log_line("storage_open: жду загрузку (асинхронно, до #{OPEN_TIMEOUT_S.to_i} с на попытку)")
        end
        storage_open_tick
      end

      # Тик опроса (секвенсор, повторяющийся таймер). :in_progress — ждём
      # загрузку/пробуем дальше; String — шаг завершён.
      def storage_open_tick
        so = @storage_open
        return 'нет активного шага открытия' if so.nil?

        if cancelled?
          so['val'] << 'отменено пользователем' if so['opens'].empty?
          return storage_open_finish('cancelled')
        end

        cur = Sketchup.active_model
        cur_path = cur&.path.to_s
        if cur_path != so['last_seen']
          so['last_seen'] = cur_path
          log_line("storage_open: активная модель — #{cur_path.empty? ? '(без имени)' : File.basename(cur_path)}")
        end

        if so['waiting']
          # ВАЖНО: SU2025 может ПЕРЕИСПОЛЬЗОВАТЬ объект модели — безымянная
          # вкладка «становится» открытым файлом (тот же Ruby-объект, путь
          # меняется). Поэтому успех определяем ТОЛЬКО по пути, не по
          # идентичности объекта.
          if !cur.nil? && File.basename(cur_path.downcase) == File.basename(so['path'].downcase)
            # Файл теста открылся: замер от вызова open_file до смены модели.
            so['opens'] << (Dn1supBenchmark.monotonic - so['t0'])
            n = cur.entities.size
            so['val'] << "открытие #{so['i']}: сущностей #{n} (ожидали > 0)" unless n.positive?
            storage_close_tab(so)
            so['waiting'] = false
            so['i'] += 1
          elsif Dn1supBenchmark.monotonic - so['t0'] > OPEN_TIMEOUT_S
            so['val'] << "открытие #{so['i']}: файл не открылся за #{OPEN_TIMEOUT_S.to_i} с"
            so['waiting'] = false
            so['i'] += 1
          else
            return :in_progress # загрузка ещё идёт — тик секвенсора вернётся
          end
        end

        while so['i'] < so['iters']
          so['t0'] = Dn1supBenchmark.monotonic
          begin
            open_file_status(so['path'])
            so['waiting'] = true
            return :in_progress
          rescue StandardError => e
            so['diag'] << diag_hash(e)
            so['i'] += 1
          end
        end

        storage_open_finish
      end

      def same_path?(a, b)
        a.to_s.tr('\\', '/').downcase == b.to_s.tr('\\', '/').downcase
      end

      # Закрыть вкладку файла теста (только по имени файла — модель
      # пользователя не трогаем; объект мог переиспользоваться — см. выше).
      def storage_close_tab(so)
        cur = Sketchup.active_model
        return if cur.nil?
        return unless File.basename(cur.path.to_s.downcase) == File.basename(so['path'].downcase)

        cur.close(true)
        nil
      end

      def storage_open_finish(status = nil)
        so = @storage_open
        med_s = median(so['opens'])
        size = so['size']
        mbps = med_s && med_s.positive? ? (size / 1_048_576.0) / med_s : nil
        add_result('storage', 'storage_open',
                   "Открытие файла #{(size / 1_048_576.0).round} МБ", 'ms', so['opens'],
                   ops: 1, file_size: size,
                   params: { 'target_mb' => @state['params']['target_mb'],
                             'op' => 'Sketchup.open_file (async) + close(true)',
                             'open_file' => 'асинхронный: тайминг от вызова до смены активной модели (тики 0.3 с)',
                             'cache' => 'файловый кэш ОС тёплый; «холодный» запуск не заявляется',
                             'note' => 'открытие атомарно — UI блокируется на время загрузки' },
                   extra: { 'mb_per_s' => mbps&.round(1),
                            'file_mb' => (size / 1_048_576.0).round(1) },
                   diagnostics: so['diag'], validation_errors: so['val'],
                   status: status || status_for(so['opens'], so['diag'], so['val']))
        log_line("storage: открытие #{mb_str(size)} (#{so['opens'].size} повторов)")
        storage_close_tab(so) # страховка: вкладка теста не должна остаться
        begin
          File.delete(so['path']) if File.exist?(so['path'])
        rescue StandardError
          nil
        end
        @storage_open = nil
        status == 'cancelled' ? 'cancelled: storage_open' : 'ok: storage_open'
      end

      # Асинхронный старт загрузки (см. storage_open_tests).
      def open_file_status(path)
        if Sketchup.version.to_i >= 24
          Sketchup.open_file(path, with_status: true)
        else
          Sketchup.open_file(path)
        end
      rescue ArgumentError
        Sketchup.open_file(path)
      end

      def mb_str(bytes)
        "#{(bytes.to_f / 1_048_576.0).round(1)} МБ"
      end

      # open_file без предупреждения о устаревшей перегрузке (SU2024+
      # рекомендует with_status: true; на старых версиях — обычный вызов).
      def open_file_status(path)
        if Sketchup.version.to_i >= 24
          Sketchup.open_file(path, with_status: true)
        else
          Sketchup.open_file(path)
        end
      rescue ArgumentError
        Sketchup.open_file(path)
      end

      # Свободное место на диске (GetDiskFreeSpaceExW через Fiddle; вне
      # Windows или при сбое — nil, проверка пропускается).
      def disk_free_bytes(dir)
        return nil unless RUBY_PLATFORM.match?(/mingw|mswin|win32/) && defined?(Fiddle)

        ptr = [0].pack('Q<')
        total = [0].pack('Q<')
        path = (dir.to_s.gsub('/', '\\') + "\\").encode('UTF-16LE').force_encoding('ASCII-8BIT')
        fn = Fiddle::Function.new(Fiddle.dlopen('kernel32.dll')['GetDiskFreeSpaceExW'],
                                  [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                   Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                                  Fiddle::TYPE_INT)
        ok = fn.call(path, ptr, total, nil)
        ok.nonzero? ? ptr.unpack1('Q<') : nil
      rescue StandardError
        nil
      end

      # -- финал ------------------------------------------------------------------------

      def finish_run
        return 'нет активного прогона' if @state.nil?

        fps_stop_tool
        close_scene
        data = run_data
        data['score'] = Score.compute(data) # необязательный общий балл
        @last_run_data = data
        @state = nil
        @scene_state = nil
        @run_model = nil
        @baseline_entities = nil
        @cancel_requested = false
        paths = Report.save_run(data)
        Dn1supBenchmark.last_report = paths['html']
        { 'status' => data['run']['status'], 'json' => paths['json'], 'html' => paths['html'],
          'tests' => data['results'].size,
          'errors' => data['results'].count { |r| r['status'] != 'passed' } }
      end

      def run_data
        return nil if @state.nil?

        { 'meta' => @state['meta'], 'results' => @state['results'].dup,
          'run' => { 'profile' => @state['profile'], 'status' => cancelled? ? 'cancelled' : 'completed',
                     'started_at' => @state['meta']['started_at'] },
          'log' => @state['log'].dup }
      end

      # Данные последнего завершённого прогона (для вкладки «Результаты»).
      def last_run_data
        @last_run_data
      end

      # -- измерительный каркас -------------------------------------------------------------

      # measure: iters повторов блока; блок возвращает результат итерации
      # (передаётся в validate/cleanup). Валидация и очистка — ВНЕ замера.
      # Ошибка итерации → диагностика; частичный успех → passed с диагностикой.
      def measure(group, id, name, unit, iters, opts = {}, &blk)
        times = []
        diag = []
        val = []
        results = []
        validate = opts[:validate]
        cleanup = opts[:cleanup]
        iters.times do |i|
          raise Cancelled if cancelled?

          begin
            t0 = Dn1supBenchmark.monotonic
            res = blk.call(i)
            times << (Dn1supBenchmark.monotonic - t0)
            results << res
          rescue Cancelled
            raise
          rescue StandardError => e
            diag << diag_hash(e)
            log_line("#{id}: #{e.class}: #{e.message}")
            break
          end
          if validate
            begin
              val.concat(validate.call(res, i))
            rescue StandardError => e
              diag << diag_hash(e)
            end
          end
          if cleanup
            begin
              cleanup.call(res, i)
            rescue StandardError => e
              diag << diag_hash(e)
            end
          end
        end
        GC.start
        add_result(group, id, name, unit, times,
                   entities: opts[:entities], entities_created: opts[:entities_created],
                   higher: opts[:higher] || false, params: opts[:params], ops: opts[:ops],
                   file_size: opts[:file_size], diagnostics: diag,
                   validation_errors: val, status: status_for(times, diag, val))
      end

      # measure_op: как measure, но с setup/check/cleanup на каждую итерацию —
      # для тестов, где фиксстру перед операцией надо строить и убирать вне
      # замера (follow me, intersect, черчение).
      #   setup(i)   → ctx (вне замера);
      #   yield(ctx) → результат операции (замеряется);
      #   check(res, ctx) → [ошибки валидации] (вне замера);
      #   cleanup(res, ctx) (вне замера).
      def measure_op(group, id, name, unit, iters, opts = {}, &blk)
        times = []
        diag = []
        val = []
        iters.times do |i|
          raise Cancelled if cancelled?

          ctx = nil
          res = nil
          begin
            ctx = opts[:setup] ? opts[:setup].call(i) : nil
            t0 = Dn1supBenchmark.monotonic
            res = blk.call(ctx, i)
            times << (Dn1supBenchmark.monotonic - t0)
          rescue Cancelled
            raise
          rescue StandardError => e
            diag << diag_hash(e)
            log_line("#{id}: #{e.class}: #{e.message}")
            break
          end
          if opts[:check]
            begin
              val.concat(opts[:check].call(res, ctx) || [])
            rescue StandardError => e
              diag << diag_hash(e)
            end
          end
          next unless opts[:cleanup]

          begin
            opts[:cleanup].call(res, ctx)
          rescue StandardError => e
            diag << diag_hash(e)
          end
        end
        GC.start
        add_result(group, id, name, unit, times,
                   entities: opts[:entities], entities_created: opts[:entities_created],
                   higher: opts[:higher] || false, params: opts[:params], ops: opts[:ops],
                   file_size: opts[:file_size], diagnostics: diag,
                   validation_errors: val, status: status_for(times, diag, val))
      end

      # Единая сборка записи результата (контракт теста, схема v1).
      def add_result(group, id, name, unit, times, opts = {})
        times = Array(times)
        higher = opts.fetch(:higher, false)
        diag = opts[:diagnostics] || []
        val = opts[:validation_errors] || []
        # Для fps в times_ms лежат сами значения fps (повтор один).
        stats_vals = unit == 'fps' ? times : times.map { |t| (t * 1000).round(1) }
        med = median(stats_vals)
        rec = {
          'id' => id, 'name' => name, 'group' => group, 'category' => group,
          'test_version' => TEST_VERSION, 'unit' => unit,
          'higher_is_better' => higher,
          'status' => opts[:status] || (times.empty? ? 'failed' : 'passed'),
          'parameters' => opts[:params] || {},
          'repeat_count' => stats_vals.size,
          'times_ms' => stats_vals,
          'median_ms' => unit == 'fps' ? nil : med,
          'min_ms' => unit == 'fps' ? nil : stats_vals.min,
          'max_ms' => unit == 'fps' ? nil : stats_vals.max,
          'p95_ms' => p95(stats_vals),
          'ops_per_sec' => ops_per_sec(opts[:ops], med),
          'entities' => opts[:entities],
          'entities_created' => opts[:entities_created],
          'file_size_bytes' => opts[:file_size],
          'validation' => { 'passed' => val.empty?, 'errors' => val },
          'error' => diag.empty? ? (val.empty? ? nil : val.first) : "#{diag.first['class']}: #{diag.first['message']}",
          'diagnostics' => diag,
          'value' => med
        }
        rec.merge!(opts[:extra]) if opts[:extra]
        @state['results'] << rec if @state
        rec
      end

      def add_skipped(group, id, name, reason, status: 'skipped')
        rec = { 'id' => id, 'name' => name, 'group' => group, 'category' => group,
                'test_version' => TEST_VERSION, 'unit' => nil, 'higher_is_better' => false,
                'status' => status, 'parameters' => {}, 'repeat_count' => 0, 'times_ms' => [],
                'median_ms' => nil, 'min_ms' => nil, 'max_ms' => nil, 'p95_ms' => nil,
                'ops_per_sec' => nil, 'entities' => nil, 'entities_created' => nil,
                'file_size_bytes' => nil,
                'validation' => { 'passed' => false, 'errors' => [reason] },
                'error' => reason, 'diagnostics' => [], 'value' => nil }
        @state['results'] << rec if @state
        rec
      end

      # Статус по итогам повторов: нет ни одного успешного повтора → failed
      # (диагностика/валидация объясняют причину); частичный успех → passed
      # с сохранённой диагностикой (медленные повторы не выбрасываются).
      def status_for(times, _diag, _val)
        times.empty? ? 'failed' : 'passed'
      end

      def median(values)
        return nil if values.nil? || values.empty?

        s = values.sort
        n = s.size
        n.odd? ? s[n / 2] : ((s[n / 2 - 1] + s[n / 2]) / 2.0).round(2)
      end

      def median_ms(times_s)
        med = median(times_s.map { |t| (t * 1000).round(1) })
        med&.round(1)
      end

      # p95 методом ближайшего ранга; при n<10 осмысленного перцентиля нет → nil.
      def p95(values)
        return nil if values.nil? || values.size < 10

        s = values.sort
        idx = [((0.95 * s.size).ceil) - 1, s.size - 1].min
        s[idx]
      end

      def ops_per_sec(ops, median_val)
        return nil if ops.nil? || median_val.nil? || median_val <= 0

        (ops / (median_val / 1000.0)).round(1)
      end

      def diag_hash(e)
        { 'class' => e.class.name, 'message' => e.message.to_s,
          'backtrace' => Array(e.backtrace).first(5) }
      end

      # -- контекст и утилиты ---------------------------------------------------------------

      def leave_edit_context(model)
        return if model.active_path.nil? || model.active_path.empty?

        begin
          model.active_path = []
        rescue StandardError
          begin
            model.active_path = nil
          rescue StandardError
            nil
          end
        end
      end

      def log_line(msg)
        line = "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
        @state['log'] << line if @state
        puts "[dn1sup_benchmark] #{msg}"
        # Пульс в файл: переживает падение процесса (диагностика крашей).
        begin
          File.open(File.join(PngGen.temp_root, 'run_heartbeat.log'), 'a') { |fh| fh.puts line }
        rescue StandardError
          nil
        end
      end

      def deep_copy(obj)
        Marshal.load(Marshal.dump(obj))
      end
    end
  end
end
