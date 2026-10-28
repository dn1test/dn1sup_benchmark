# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/runner.rb — методика и выполнение бенчмарка (набор v2).
#
# Прогон = последовательность ШАГОВ (Runner.steps): begin → RUBY-01 → сцены
# (в каждой — синхронные тесты) → FPS-шаги → DOC-шаг → finish. Один и тот же
# план исполняется двумя способами:
#   • из меню/диалога — секвенсор на UI.start_timer (sequencer.rb): UI не
#     блокируется, FPS-метр получает честные кадры;
#   • через мост — пошагово отдельными eval (command.rb), между :fps и сбором
#     результата клиент выдерживает паузу сам.
#
# Сцена живёт внутри одной undo-операции: start_operation → build → тесты →
# clear! + abort_operation (проверенный паттерн). Модель пользователя после
# прогона возвращается к исходному состоянию, undo-стек не засоряется.
# API-06 намеренно выполняет вложенные операции УРОВНЯ 1 внутри операции
# сцены — методика зафиксирована в параметрах теста (nested_in_scene_op).
#
# Замеры: только Process.clock_gettime(CLOCK_MONOTONIC); повтор count раз;
# статистика median/min/max + p95 (n>=10); GC.start между тестами. Каждый
# результат несёт контракт теста (см. schemas/result-schema-v1.json): id,
# test_version, категория, статус passed/failed/cancelled/skipped, параметры,
# валидация и диагностика. Ошибка теста не роняет прогон.
#
# Отмена: Runner.cancel! поднимает флаг; между повторами и между шагами
# выполняющий код бросает Cancelled — результат получает статус cancelled,
# отчёт всё равно сохраняется.
# =============================================================================

require 'json'

module Dn1supBenchmark
  module Runner
    # Версия НАБОРА тестов: меняется при изменении состава/методики
    # (сравнение прогонов с разными suite-версиями помечается несовместимым).
    SUITE_VERSION = '2'
    # Версия конкретного теста: менять при изменении его измеряемой операции.
    TEST_VERSION = '1'

    # Категории таксономии ТЗ; group в результате = категория.
    GROUP_TITLES = {
      'ruby' => 'Чистый Ruby',
      'api' => 'SketchUp API',
      'documents' => 'Файлы (документы)',
      'graphics' => 'Графика (вьюпорт)',
      # легаси-имена групп из отчётов 0.1.0 — только для отображения старых HTML
      'scene_gen' => 'Построение сцен (ядро геометрии)',
      'viewport' => 'Вьюпорт (FPS рендера)',
      'hierarchy' => 'Навигация по иерархии',
      'editing' => 'Редактирование',
      'textures' => 'Материалы и текстуры'
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

    # Профили ТЗ: явные цели по рёбрам/инстансам; параметры сцен выводятся
    # формулами и записываются в отчёт (meta.params + параметры каждого теста).
    #   grid n          → n² граней, ≈2·n·(n+1) рёбер (смежная сетка);
    #   components grid → grid² верхних инстансов сборок;
    #   api01_loops     → loops контуров × 4 ребра + loops граней.
    PROFILES = {
      'small' => {
        'targets' => { 'edges' => 10_000, 'instances' => 100 },
        'grid' => { 'n' => 70 },
        'components' => { 'defs' => 12, 'assemblies' => 6, 'per_assembly' => 4, 'grid' => 10 },
        'nested' => { 'depth' => 6, 'items' => 4 },
        'textured' => { 'boxes' => 24 },
        'api01_loops' => 2_500,
        'api02_groups' => 100,
        'api03_defs' => 10, 'api03_instances' => 100,
        'api05_objects' => 100,
        'api06_faces' => 100,
        'fps_s' => 1.5, 'iters' => 3,
        'pushpull' => 8, 'move' => 10, 'add_faces' => 8, 'tex_apply' => 60,
        'doc_enabled' => true
      },
      'medium' => {
        'targets' => { 'edges' => 100_000, 'instances' => 1_000 },
        'grid' => { 'n' => 223 },
        'components' => { 'defs' => 24, 'assemblies' => 10, 'per_assembly' => 6, 'grid' => 32 },
        'nested' => { 'depth' => 6, 'items' => 12 },
        'textured' => { 'boxes' => 96 },
        'api01_loops' => 25_000,
        'api02_groups' => 1_000,
        'api03_defs' => 24, 'api03_instances' => 1_000,
        'api05_objects' => 500,
        'api06_faces' => 400,
        'fps_s' => 3.0, 'iters' => 4,
        'pushpull' => 40, 'move' => 40, 'add_faces' => 20, 'tex_apply' => 400,
        'doc_enabled' => true
      },
      'large' => {
        'targets' => { 'edges' => 500_000, 'instances' => 10_000 },
        'grid' => { 'n' => 500 },
        'components' => { 'defs' => 32, 'assemblies' => 12, 'per_assembly' => 8, 'grid' => 100 },
        'nested' => { 'depth' => 6, 'items' => 12 },
        'textured' => { 'boxes' => 240 },
        # Цель «500 тыс. рёбер» обеспечивает сцена grid (500×500 ≈ 501 тыс.
        # рёбер). API-01 ограничен: 125 тыс. контуров в одной коллекции
        # деградируют по скорости на порядки (замерено 2026-10-28, SU2027 —
        # часы работы), повторяя нагрузку grid без новой информации.
        'api01_loops' => 25_000,
        # api02 ограничен 1000 групп на всех тяжёлых профилях — сами по себе
        # группы дорогие, цель профиля отражают api01/api03 (зафиксировано).
        'api02_groups' => 1_000,
        'api03_defs' => 32, 'api03_instances' => 10_000,
        'api05_objects' => 1_000,
        'api06_faces' => 400,
        'fps_s' => 2.0, 'iters' => 2,
        'pushpull' => 40, 'move' => 40, 'add_faces' => 20, 'tex_apply' => 400,
        'doc_enabled' => true
      }
    }.freeze

    # Ключи, которые пользователь может переопределить (Настройки диалога).
    OVERRIDABLE = %w[iters fps_s doc_enabled].freeze

    PROFILE_WARNINGS = {
      'large' => 'Профиль large строит ~500 000 рёбер и ~10 000 инстансов: ' \
                 'прогон может занять десятки минут и сильно нагрузить систему.',
      'custom' => 'Пользовательский профиль: нагрузка определяется вашими параметрами.'
    }.freeze

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

      # -- параметры профилей ------------------------------------------------------

      def profile_params(profile, overrides = nil)
        base = PROFILES[profile]
        if base.nil? && profile != 'custom'
          raise ArgumentError, "неизвестный профиль: #{profile}"
        end
        if base.nil? && !overrides.is_a?(Hash)
          raise ArgumentError, 'профилю custom нужен полный набор параметров'
        end

        params = base ? deep_copy(base) : deep_copy(overrides)
        if base && overrides.is_a?(Hash)
          overrides.each do |k, v|
            params[k] = v if OVERRIDABLE.include?(k)
          end
        end
        params['profile'] = profile
        params
      end

      def profile_warning(profile)
        PROFILE_WARNINGS[profile]
      end

      # -- план прогона --------------------------------------------------------------

      def steps(profile, overrides = nil)
        profile_params(profile, overrides) # валидация профиля до старта
        [
          { 'kind' => 'begin', 'profile' => profile, 'overrides' => overrides, 'label' => 'Инициализация' },
          { 'kind' => 'ruby', 'category' => 'ruby', 'label' => 'RUBY-01: чистый Ruby' },
          { 'kind' => 'scene', 'scene' => 'basics', 'category' => 'api',
            'label' => 'API-01…03, 05: рёбра/грани, группы, компоненты, атрибуты' },
          { 'kind' => 'scene', 'scene' => 'nested', 'category' => 'api',
            'label' => 'Сцена: вложенные группы (иерархия)' },
          { 'kind' => 'scene', 'scene' => 'components', 'category' => 'api',
            'label' => 'Сцена: компоненты (обход API-04, правки)' },
          { 'kind' => 'fps', 'id' => 'fps_components_static', 'mode' => 'static', 'category' => 'graphics',
            'name' => 'FPS: компоненты, статичный вид' },
          { 'kind' => 'scene', 'scene' => 'grid', 'category' => 'api',
            'label' => 'Сцена: плотная сетка (API-06, pushpull, zoom, страницы)' },
          { 'kind' => 'fps', 'id' => 'fps_grid_static', 'mode' => 'static', 'category' => 'graphics',
            'name' => 'FPS: сетка, статичный вид' },
          { 'kind' => 'fps', 'id' => 'fps_grid_orbit', 'mode' => 'orbit', 'category' => 'graphics',
            'name' => 'FPS: сетка, орбита' },
          { 'kind' => 'fps', 'id' => 'fps_grid_pan', 'mode' => 'pan', 'category' => 'graphics',
            'name' => 'FPS: сетка, панорамирование' },
          { 'kind' => 'fps', 'id' => 'fps_grid_zoom', 'mode' => 'zoom', 'category' => 'graphics',
            'name' => 'FPS: сетка, зум' },
          # Переключение сцен (Pages#selected_page=) автоматизировано НЕ будет:
          # применение страницы внутри открытой undo-операции фиксирует
          # транзакцию ядра, и последующий abort уже не откатывает контент
          # (инцидент 2026-10-28, SU2027 — см. README). Ручной сценарий.
          { 'kind' => 'scene', 'scene' => 'textured', 'category' => 'api',
            'label' => 'Сцена: текстуры (назначение, перекраска)' },
          { 'kind' => 'fps', 'id' => 'fps_textured_static', 'mode' => 'static', 'category' => 'graphics',
            'name' => 'FPS: текстуры, статичный вид' },
          { 'kind' => 'doc', 'category' => 'documents', 'label' => 'DOC-01/02: сохранение и открытие контрольной модели' },
          { 'kind' => 'finish', 'label' => 'Отчёт' }
        ]
      end

      # Краткое описание плана для UI (без исполнения).
      def plan_preview(profile, overrides = nil)
        params = profile_params(profile, overrides)
        {
          'profile' => profile,
          'params' => params,
          'warning' => profile_warning(profile),
          'steps' => steps(profile, overrides).map do |s|
            { 'kind' => s['kind'], 'label' => s['label'] || s['name'], 'category' => s['category'] }
          end
        }
      end

      # -- исполнение шагов ------------------------------------------------------------

      def perform(step)
        case step['kind']
        when 'begin'  then begin_run(step['profile'], step['overrides'])
        when 'ruby'   then run_ruby_test
        when 'scene'  then open_scene(step['scene'])
        when 'fps'    then fps_start(step)
        when 'doc'    then run_doc_tests
        when 'finish' then finish_run
        else "неизвестный шаг: #{step['kind']}"
        end
      ensure
        # Шаги, трогающие модель, обязаны остаться на модели прогона.
        guard_model! if %w[scene fps doc].include?(step['kind'])
      end

      def begin_run(profile, overrides = nil)
        params = profile_params(profile, overrides)
        model = Sketchup.active_model
        raise 'нет активной модели' if model.nil?

        close_scene # страховка: не должно быть висящей операции
        @cancel_requested = false
        @run_model = model
        @baseline_entities = model.entities.size
        @state = {
          'profile' => profile,
          'params' => params,
          'meta' => Environment.context(profile, params),
          'results' => [],
          'scene' => nil,
          'scene_info' => nil,
          'log' => []
        }
        PngGen.cached_textures([256, 1024, 2048]) # генерация вне замеров
        log_line("прогон начат (#{profile})")
        'ok'
      end

      # Защита: каждый шаг и каждая очистка обязаны работать с той моделью,
      # на которой прогон был начат. Иначе — аварийный стоп без очистки.
      def guard_model!
        return if @run_model.nil?
        return if Sketchup.active_model.equal?(@run_model)

        raise ModelChanged
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

      def record_scene_gen(name, dt, info)
        @state['scene_info'] = info
        GC.start
        if info['entities'].to_i.positive?
          add_result('api', "scene_gen_#{name}", "Построение: #{scene_title(name)}",
                     'ms', [dt], entities: info['entities'],
                     params: scene_params(name))
        end
        log_line("сцена #{name}: #{(dt * 1000).round} мс, entities=#{info['entities']}")
      end

      # План работ сцены: построение (кусками для тяжёлых сцен) + тесты.
      def scene_plan(name, model)
        st = @scene_state
        p = @state['params']
        case name
        when 'basics'
          plan_basics(st, model, p)
        when 'nested'
          st['jobs'] << [:sync, -> {
            t0 = Dn1supBenchmark.monotonic
            info = Scenes.build_nested(model, p['nested']['depth'], p['nested']['items'])
            record_scene_gen('nested', Dn1supBenchmark.monotonic - t0, info)
            tests_nested(model, p)
            st['result'] = "ok: nested (entities=#{info['entities']})"
          }]
        when 'components'
          cp = p['components']
          top = cp['grid'] * cp['grid']
          total = top + cp['assemblies'] * cp['per_assembly']
          build = make_task(
            [
              { 'timed' => true, 'total' => cp['defs'], 'batch' => cp['defs'],
                'work' => ->(from, to, ctx) {
                  (ctx['leaf'] ||= []).concat(Scenes.components_leaf_defs(model, from, to, cp['defs']))
                } },
              { 'timed' => true, 'total' => cp['assemblies'], 'batch' => cp['assemblies'],
                'work' => ->(from, to, ctx) {
                  (ctx['asm'] ||= []).concat(Scenes.components_asm_defs(model, ctx['leaf'], from, to,
                                                                        cp['assemblies'], cp['per_assembly'], cp['defs']))
                } },
              { 'timed' => true, 'total' => top, 'batch' => [top, 512].min,
                'work' => ->(from, to, ctx) {
                  Scenes.components_top(model, ctx['asm'], from, to, cp['grid'], cp['assemblies'])
                } }
            ],
            ->(_times, _ph, _ctx) {
              info = { 'entities' => total, 'top_instances' => top,
                       'leaf_defs' => cp['defs'], 'asm_defs' => cp['assemblies'],
                       'total_instances' => total }
              record_scene_gen('components', build['phases'].sum { |ph| ph['sums'].to_f }, info)
            }
          )
          st['jobs'] << [:task, build]
          st['jobs'] << [:sync, -> {
            tests_components(model, p)
            st['result'] = "ok: components (entities=#{total})"
          }]
        when 'grid'
          n = p['grid']['n']
          build = make_task(
            [{ 'timed' => true, 'total' => n, 'batch' => [n, 8].min,
               'work' => ->(from, to, _ctx) {
                 from.upto(to - 1) { |i| Scenes.grid_row(model, n, i) }
               } }],
            ->(_times, _ph, _ctx) {
              record_scene_gen('grid', build['phases'][0]['sums'].to_f,
                               { 'entities' => n * n, 'n' => n, 'faces' => n * n })
            }
          )
          st['jobs'] << [:task, build]
          st['jobs'] << [:sync, -> { tests_grid(model, p) }]
          st['jobs'] << [:task, api06_task(model, p)]
          st['jobs'] << [:sync, -> { st['result'] = "ok: grid (#{n * n} граней)" }]
        when 'textured'
          boxes = p['textured']['boxes']
          build = make_task(
            [{ 'timed' => true, 'total' => boxes, 'batch' => [boxes, 64].min,
               'work' => ->(from, to, _ctx) {
                 from.upto(to - 1) { |i| Scenes.textured_box(model, boxes, i) }
               } }],
            ->(_times, _ph, _ctx) {
              record_scene_gen('textured', build['phases'][0]['sums'].to_f,
                               { 'entities' => boxes * 6, 'boxes' => boxes })
            }
          )
          st['jobs'] << [:task, build]
          st['jobs'] << [:sync, -> {
            tests_textured(model, p)
            st['result'] = "ok: textured (#{boxes} боксов)"
          }]
        else
          raise ArgumentError, "неизвестная сцена: #{name}"
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

      # -- RUBY-01 ---------------------------------------------------------------------

      def run_ruby_test
        return 'нет активного прогона' if @state.nil?

        params = @state['params']
        guard_model!
        spec = RubyWorkload.spec
        measure('ruby', 'RUBY-01', 'Чистый Ruby: массивы, хеши, арифметика',
                'ms', params['iters'],
                params: spec.merge('profile_note' => 'фиксированная нагрузка без обращения к SketchUp API'),
                ops: RubyWorkload::TOTAL_OPS) do |_i|
          RubyWorkload.run
        end
        'ok: RUBY-01'
      end

      # -- FPS (асинхронно: start → кадры идут в UI-потоке → collect) -------------------

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

      def fps_collect
        return 'нет активного FPS-замера' if @tool.nil?

        step = @fps_step
        result = @tool.result || @tool.stop_now
        fps_stop_tool
        if cancelled?
          add_skipped('graphics', step['id'], step['name'], 'отменено пользователем', status: 'cancelled')
          return 'cancelled'
        end
        if result.nil? || result['frames'].to_i.zero?
          rec = add_result('graphics', step['id'], step['name'], 'fps', [],
                           status: 'failed',
                           diagnostics: [{ 'class' => 'RuntimeError', 'message' => 'кадры не отрисовались', 'backtrace' => [] }])
          log_line("#{step['id']}: кадры не отрисовались")
          return rec
        end
        add_result('graphics', step['id'], step['name'], 'fps',
                   [result['fps']], higher: true,
                   entities: result['frames'],
                   params: { 'duration_s' => result['elapsed_s'],
                             'transition_time' => 'настройка приложения, через API недоступна',
                             'source' => 'счётчик кадров Tool#draw + view.invalidate (Ruby-сторона, не GPU-счётчик)' },
                   extra: { 'frames' => result['frames'], 'elapsed_s' => result['elapsed_s'], 'mode' => result['mode'] })
        log_line("#{step['id']}: #{result['fps']} fps (#{result['frames']} кадров)")
        "ok: #{result['fps']} fps"
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

      # -- DOC-01/02 --------------------------------------------------------------------

      # Контрольная модель = определение с фиксированными боксами, сохранённое
      # через ComponentDefinition#save_copy во временную папку. Пользовательская
      # модель не сохраняется и не перезаписывается; после открытия фикстура
      # закрывается без сохранения. Файловый кэш ОС тёплый — «холодный запуск»
      # НЕ заявляется (см. параметры теста).
      def run_doc_tests
        return 'нет активного прогона' if @state.nil?

        params = @state['params']
        return add_skipped('documents', 'DOC-01', 'Сохранение контрольной модели', 'отключено в настройках') unless params['doc_enabled']

        close_scene
        model = Sketchup.active_model
        raise 'нет активной модели' if model.nil?

        orig_model = model
        dir = PngGen.mkdir_p(File.join(PngGen.temp_root, 'docs'))
        stamp = Time.now.strftime('%Y%m%d-%H%M%S')
        fixture_path = File.join(dir, "fixture_#{stamp}.skp")
        save_path = File.join(dir, "saved_#{stamp}.skp")
        boxes = 60
        iters = [params['iters'], 3].min

        begin
          build_doc_fixture(model, fixture_path, boxes)
          file_size = File.size(fixture_path)
          expected_faces = boxes * 6

          # DOC-02: открытие (каждый повтор: open → валидация → close)
          opens = []
          diag = []
          val = []
          iters.times do |i|
            raise Cancelled if cancelled?

            t0 = Dn1supBenchmark.monotonic
            ok = Sketchup.open_file(fixture_path)
            t1 = Dn1supBenchmark.monotonic
            opened = Sketchup.active_model
            if !ok || opened.nil? || opened == orig_model
              val << "открытие #{i}: open_file не создал новую модель"
              next
            end
            n = opened.entities.grep(Sketchup::Face).size
            val << "открытие #{i}: граней #{n} вместо #{expected_faces}" if n != expected_faces
            opened.close(true)
            opens << (t1 - t0)
          rescue StandardError => e
            diag << diag_hash(e)
          end
          add_result('documents', 'DOC-02', 'Открытие контрольной модели', 'ms', opens,
                     params: doc_params(fixture_path, file_size),
                     file_size: file_size,
                     diagnostics: diag, validation_errors: val,
                     status: status_for(opens, diag, val))

          # DOC-01: сохранение (модель открыта один раз, save ×iters)
          saves = []
          sizes = []
          diag = []
          val = []
          begin
            raise Cancelled if cancelled?

            ok = Sketchup.open_file(fixture_path)
            opened = Sketchup.active_model
            raise 'контрольная модель не открылась' if !ok || opened.nil? || opened == orig_model

            iters.times do |i|
              raise Cancelled if cancelled?

              t0 = Dn1supBenchmark.monotonic
              opened.save(save_path)
              t1 = Dn1supBenchmark.monotonic
              saves << (t1 - t0)
              sizes << (File.exist?(save_path) ? File.size(save_path) : 0)
            end
            opened.close(true)
          rescue Cancelled
            raise
          rescue StandardError => e
            diag << diag_hash(e)
          end
          add_result('documents', 'DOC-01', 'Сохранение контрольной модели', 'ms', saves,
                     params: doc_params(save_path, sizes.last).merge('size_bytes_repeats' => sizes),
                     file_size: sizes.last,
                     diagnostics: diag, validation_errors: val,
                     status: status_for(saves, diag, val))
        ensure
          # Если фикстура осталась открыта (исключение посередине) — закрываем.
          cur = Sketchup.active_model rescue nil
          if cur && cur != orig_model
            begin
              cur.close(true)
            rescue StandardError
              nil
            end
          end
          log_line("DOC: файлы в #{dir} (не удаляются — можно посмотреть вручную)")
        end
        'ok: DOC-01/02'
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

      # -- сцена nested: иерархия --------------------------------------------------------

      def tests_nested(model, params)
        path = @state['scene_info']['path']

        # Полный цикл: спуск до дна иерархии, подъём обратно. Одна итерация =
        # один цикл. Синхронный вызов active_path= — само ядро навигации.
        measure('api', 'hierarchy_open_close', 'Вход/выход: полный спуск-подъём (6 уровней)',
                'ms', params['iters'],
                entities: path.size, params: { 'depth' => path.size }) do |_i|
          path.each_index do |d|
            set_active_path(model, path[0..d])
          end
          (path.size - 1).downto(0) do |d|
            set_active_path(model, d.zero? ? [] : path[0..d - 1])
          end
          leave_edit_context(model)
        end

        # Пошаговый спуск: замер каждого уровня отдельно.
        times = []
        path.each_index do |d|
          t0 = Dn1supBenchmark.monotonic
          set_active_path(model, path[0..d])
          times << Dn1supBenchmark.monotonic - t0
        end
        leave_edit_context(model)
        add_result('api', 'hierarchy_step_dive', 'Пошаговый спуск по уровням (медиана шага)',
                   'ms', times, entities: path.size, params: { 'depth' => path.size })
      end

      # -- сцена basics: API-01/02/03/05 ---------------------------------------------------
      # API-01 и API-03 — кусочные задачи (тяжёлые: сотни тысяч вызовов API);
      # API-02 и API-05 — синхронные (лёгкие). План собирается в plan_basics.

      def plan_basics(st, model, p)
        st['jobs'] << [:task, api01_task(model, p['api01_loops'], p['iters'])]
        st['jobs'] << [:sync, -> { test_api02(model, p) }]
        # Определения для API-03 — дешёвый setup: строим сразу при
        # планировании (аргумент задачи вычисляется здесь же, а не в тике).
        defs = build_api03_defs(model, p['api03_defs'])
        st['jobs'] << [:task, api03_task(model, defs, p['api03_instances'], p['iters'])]
        st['jobs'] << [:sync, -> {
          test_api05(model, p)
          st['result'] = 'ok: basics'
        }]
      end

      def api01_loop(model, k)
        x = (k % 500) * 300
        y = (k / 500) * 300
        p1 = [x, y, 0]
        p2 = [x + 100, y, 0]
        p3 = [x + 100, y + 100, 0]
        p4 = [x, y + 100, 0]
        ents = model.entities
        [ents.add_line(p1, p2), ents.add_line(p2, p3),
         ents.add_line(p3, p4), ents.add_line(p4, p1), ents.add_face(p1, p2, p3, p4)]
      end

      # API-01: создание рёбер и граней. Итерация = фаза создания (таймирована
      # по кускам; длительность итерации = сумма кусков) + фаза стирания
      # (вне замера, порциями). Валидация — подсчёт невалидных ссылок при
      # стирании; ошибки копятся в ctx['val'].
      def api01_task(model, loops, iters)
        phases = []
        iters.times do |i|
          phases << {
            'iter' => i, 'timed' => true, 'total' => loops, 'batch' => [loops, 400].min,
            'work' => ->(from, to, ctx) {
              refs = (ctx['refs'] ||= [])
              from.upto(to - 1) { |k| refs.concat(api01_loop(model, k)) }
            }
          }
          phases << {
            'iter' => i, 'timed' => false, 'total' => 5 * loops, 'batch' => [5 * loops, 20_000].min,
            'work' => lambda { |from, to, ctx|
              slice = ctx['refs'][from...to]
              keep = slice.select(&:valid?)
              ctx['invalid'] = (ctx['invalid'] || 0) + (slice.size - keep.size)
              model.entities.erase_entities(keep) unless keep.empty?
            },
            'on_done' => ->(ctx) {
              if (ctx['invalid'] || 0).positive?
                (ctx['val'] ||= []) << "итерация #{i}: невалидных сущностей #{ctx['invalid']} вместо 0"
              end
              ctx['refs'] = []
              ctx['invalid'] = 0
              GC.start
            }
          }
        end
        make_task(phases, ->(_times, phs, ctx) {
          iters_times = phs.select { |ph| ph['timed'] }.map { |ph| ph['sums'].to_f }
          val = ctx['val'] || []
          add_result('api', 'API-01', "Создание рёбер и граней (#{loops} контуров × 4 ребра)",
                     'ms', iters_times,
                     entities: 5 * loops, entities_created: 5 * loops, ops: 5 * loops,
                     params: { 'loops' => loops, 'edges_per_loop' => 4, 'target_edges' => 4 * loops,
                               'execution' => 'кусками ~1 с (UI отвечает, отмена активна)' },
                     diagnostics: [], validation_errors: val,
                     status: status_for(iters_times, [], val))
        })
      end

      # API-02: группы (лёгкий тест — синхронно через measure).
      def test_api02(model, params)
        ents = model.entities
        n_groups = params['api02_groups']
        measure('api', 'API-02', "Создание групп (#{n_groups} групп с гранью)",
                'ms', params['iters'],
                entities: n_groups, entities_created: n_groups, ops: n_groups,
                params: { 'groups' => n_groups, 'content' => 'уникальная группа + грань' },
                validate: proc do |groups|
                  nv = groups.count(&:valid?)
                  nv == groups.size ? [] : ["групп валидных #{nv} вместо #{groups.size}"]
                end,
                cleanup: proc { |groups| ents.erase_entities(groups.select(&:valid?)) }) do |_i|
          groups = []
          n_groups.times do |k|
            g = ents.add_group
            g.name = "dn1_g_#{k}"
            x = (k % 100) * 200
            y = 1_000_000 + (k / 100) * 200 # далеко от зоны API-01
            g.entities.add_face([x, y, 0], [x + 100, y, 0], [x + 100, y + 100, 0], [x, y + 100, 0])
            groups << g
          end
          groups
        end
      end

      # API-03: определения компонентов и экземпляры (кусочно; определения —
      # setup вне замера, переиспользуются всеми экземплярами).
      def api03_task(model, defs, n_inst, iters)
        defs ||= []
        phases = []
        iters.times do |i|
          phases << {
            'iter' => i, 'timed' => true, 'total' => n_inst, 'batch' => [n_inst, 2_000].min,
            'work' => ->(from, to, ctx) {
              refs = (ctx['refs'] ||= [])
              ents = model.entities
              from.upto(to - 1) do |k|
                defn = defs[k % defs.size]
                x = (k % 100) * 400
                y = 2_000_000 + (k / 100) * 400
                refs << ents.add_instance(defn, Geom::Transformation.new([x, y, 0]))
              end
            }
          }
          phases << {
            'iter' => i, 'timed' => false, 'total' => n_inst, 'batch' => [n_inst, 20_000].min,
            'work' => lambda { |from, to, ctx|
              slice = ctx['refs'][from...to]
              keep = slice.select(&:valid?)
              ctx['invalid'] = (ctx['invalid'] || 0) + (slice.size - keep.size)
              model.entities.erase_entities(keep) unless keep.empty?
            },
            'on_done' => ->(ctx) {
              if (ctx['invalid'] || 0).positive?
                (ctx['val'] ||= []) << "итерация #{i}: валидных инстансов не хватает (#{ctx['invalid']})"
              end
              ctx['refs'] = []
              ctx['invalid'] = 0
            }
          }
        end
        make_task(phases, ->(_times, phs, ctx) {
          iters_times = phs.select { |ph| ph['timed'] }.map { |ph| ph['sums'].to_f }
          val = ctx['val'] || []
          add_result('api', 'API-03', "Экземпляры компонентов (#{n_inst} шт., #{defs.size} определений)",
                     'ms', iters_times,
                     entities: n_inst, entities_created: n_inst, ops: n_inst,
                     params: { 'unique_definitions' => defs.size,
                               'instances_per_repeat' => n_inst,
                               'definition_reuse' => 'одно определение используется многими экземплярами' },
                     diagnostics: [], validation_errors: val,
                     status: status_for(iters_times, [], val))
        })
      end

      # API-05: атрибуты на заранее созданных объектах (якоря вне замера).
      def test_api05(model, params)
        anchors = build_api05_anchors(model, params['api05_objects'])
        measure('api', 'API-05', "Атрибуты: запись+чтение (#{anchors.size} объектов × 4 ключа)",
                'ms', params['iters'],
                entities: anchors.size, ops: anchors.size * 8,
                params: { 'objects' => anchors.size, 'keys_per_object' => 4,
                          'op' => 'set_attribute + get_attribute с проверкой обратного чтения' },
                validate: proc { |mismatches| mismatches.zero? ? [] : ["не совпало значений: #{mismatches}"] }) do |_i|
          mismatches = 0
          anchors.each_with_index do |obj, k|
            dict = 'dn1_bench'
            obj.set_attribute(dict, 'int', k)
            obj.set_attribute(dict, 'float', k * 0.5)
            obj.set_attribute(dict, 'str', "v#{k}")
            obj.set_attribute(dict, 'bool', k.even?)
            mismatches += 1 unless obj.get_attribute(dict, 'int') == k
            mismatches += 1 unless obj.get_attribute(dict, 'float') == k * 0.5
            mismatches += 1 unless obj.get_attribute(dict, 'str') == "v#{k}"
            mismatches += 1 unless obj.get_attribute(dict, 'bool') == k.even?
          end
          mismatches
        end
      end

      def build_api03_defs(model, n)
        n.times.map do |i|
          defn = model.definitions.add("dn1_api03_#{i}")
          w = 60 + (i % 4) * 20
          face = defn.entities.add_face([0, 0, 0], [w, 0, 0], [w, w, 0], [0, w, 0])
          face.pushpull(w / 2)
          defn
        end
      end

      def build_api05_anchors(model, n)
        n.times.map do |k|
          g = model.entities.add_group
          g.name = "dn1_attr_#{k}"
          x = (k % 100) * 200
          y = 3_000_000 + (k / 100) * 200
          g.entities.add_face([x, y, 0], [x + 100, y, 0], [x + 100, y + 100, 0], [x, y + 100, 0])
          g
        end
      end

      # -- сцена components: API-04 + легаси-тесты ----------------------------------------

      def tests_components(model, params)
        info = @state['scene_info']

        # API-04: обход сущностей с проверкой количества. Правила подсчёта:
        # только определения dn1_* (созданные сценой) и верхний уровень
        # model.entities — содержимое пользовательской модели не учитывается.
        expected_defs = info['leaf_defs'] + info['asm_defs']
        measure('api', 'API-04', 'Обход сущностей: подсчёт со сверкой с ожидаемым',
                'ms', params['iters'],
                entities: info['total_instances'], ops: expected_defs + 2,
                params: { 'count_rule' => 'определения dn1_* + верхний уровень model.entities',
                          'expected_top_instances' => info['top_instances'],
                          'expected_dn1_definitions' => expected_defs },
                validate: proc do |counts|
                  errs = []
                  errs << "верхних инстансов #{counts['top']} вместо #{info['top_instances']}" if counts['top'] != info['top_instances']
                  errs << "определений dn1_* #{counts['defs']} вместо #{expected_defs}" if counts['defs'] != expected_defs
                  errs << "инстансов в определениях #{counts['in_defs']} вместо #{info['total_instances']}" if counts['in_defs'] != info['total_instances']
                  errs
                end) do |_i|
          { 'top' => model.entities.grep(Sketchup::ComponentInstance).size,
            'defs' => model.definitions.count { |d| d.name.start_with?('dn1_') },
            'in_defs' => model.definitions.select { |d| d.name.start_with?('dn1_') }
                                          .sum { |d| d.instances.size } }
        end

        # Обход дерева (легаси): суммарный подсчёт инстансов по определениям.
        measure('api', 'traverse_tree', 'Обход дерева определений/инстансов',
                'ms', params['iters'], entities: info['total_instances'],
                validate: proc { |_r| [] }) do |_i|
          count = 0
          model.definitions.each { |d| count += d.instances.size }
          raise 'обход насчитал 0' if count.zero?
        end

        # Перемещение верхних инстансов (round-trip туда-обратно) — правка,
        # на которую вьюпорт отвечает пересчётом.
        tops = model.entities.grep(Sketchup::ComponentInstance).first(params['move'])
        measure('api', 'move_instances', "Перемещение инстансов (батч #{tops.size}, round-trip)",
                'ms', params['iters'], entities: tops.size, ops: tops.size,
                params: { 'batch' => tops.size, 'op' => 'transform! +50/-50 мм' }) do |i|
          dir = i.even? ? 1 : -1
          tr = Geom::Transformation.new(Geom::Vector3d.new(50 * dir, 0, 0))
          tops.each { |inst| inst.transform!(tr) }
        end

        # Правка определения: все инстансы пересчитываются. Добавляем и стираем
        # грани в листовом определении.
        defn = model.definitions['dn1_leaf_0']
        raise 'dn1_leaf_0 не найден' if defn.nil?

        measure('api', 'editing_modify_definition', "Правка определения (add+erase #{params['add_faces']} граней → пересчёт инстансов)",
                'ms', params['iters'], entities: params['add_faces'], ops: params['add_faces'] * 2,
                params: { 'add_faces' => params['add_faces'], 'effect' => 'все инстансы определения пересчитываются' }) do |_i|
          faces = []
          params['add_faces'].times do |k|
            x = 5000 + k * 120
            faces << defn.entities.add_face([x, 0, 0], [x + 100, 0, 0],
                                            [x + 100, 100, 0], [x, 100, 0])
          end
          defn.entities.erase_entities(faces)
        end
      end

      # -- сцена grid: API-06 + легаси-тесты + zoom ---------------------------------------

      def tests_grid(model, params)
        n = params['pushpull']
        # Ссылки на грани НЕ переживают push/pull (ядро пересоздаёт геометрию),
        # поэтому батч собирается заново на каждой итерации.
        measure('api', 'pushpull_batch', "Push/pull батча граней сетки (до #{n} шт.)",
                'ms', params['iters'], entities: n, ops: n,
                params: { 'batch' => n, 'op' => 'pushpull +40/-40 мм' }) do |i|
          faces = model.entities.grep(Sketchup::Face).select(&:valid?)
          h = i.even? ? 40 : -40
          faces.first(n).each { |f| f.pushpull(h) }
        end

        view = model.active_view
        measure('graphics', 'zoom_extents', 'Zoom Extents на плотной сцене',
                'ms', params['iters'], entities: model.entities.grep(Sketchup::Face).size,
                params: { 'op' => 'view.zoom_extents',
                          'note' => 'единичный вызов вида — не кускуется, может кратко занять UI' }) do |_i|
          view.zoom_extents
        end
      end

      # API-06: операции с моделью и «транзакциями». Методика (зафиксирована):
      # вложенность 1 уровень — внутри undo-операции сцены; отдельно меряется
      # время изменения (start→modify), фиксации (commit) и отмены (abort).
      # Произвольной вложенности нет; поведение отмены проверяется валидацией
      # (после abort грани обязаны стать невалидными). Кусочно: один цикл =
      # одна порция (на large это ~секунды).
      def api06_task(model, params)
        m = params['api06_faces']
        iters = params['iters']
        base_x = @state.dig('scene_info', 'n').to_i * 100 + 2_000 # правее сетки
        make_task(
          [{ 'timed' => false, 'total' => iters, 'batch' => 1,
             'work' => lambda { |from, to, ctx|
               return if ctx['stop']

               from.upto(to - 1) { |i| api06_cycle(model, base_x, m, i, ctx) }
             } }],
          ->(_times, _ph, ctx) {
            GC.start
            cycles = ctx['cycles'] || []
            diag = ctx['diag'] || []
            val = ctx['val'] || []
            add_result('api', 'API-06', 'Операции с моделью: modify / commit / abort',
                       'ms', cycles,
                       entities: m, ops: m * 2,
                       params: { 'faces_per_op' => m, 'mode' => 'start_operation → add_face×N → commit_operation',
                                 'abort_path' => 'start_operation → add_face×N → abort_operation',
                                 'nested_in_scene_op' => true, 'nested_level' => 1 },
                       diagnostics: diag, validation_errors: val,
                       status: status_for(cycles, diag, val),
                       extra: { 'modify_ms' => median_ms(ctx['modify'] || []),
                                'commit_ms' => median_ms(ctx['commits'] || []),
                                'abort_modify_ms' => median_ms(ctx['mod_aborts'] || []),
                                'abort_ms' => median_ms(ctx['aborts'] || []) })
          }
        )
      end

      def api06_cycle(model, base_x, m, i, ctx)
        ctx['modify'] ||= []; ctx['commits'] ||= []
        ctx['mod_aborts'] ||= []; ctx['aborts'] ||= []
        ctx['cycles'] ||= []; ctx['val'] ||= []; ctx['diag'] ||= []
        t0 = Dn1supBenchmark.monotonic
        model.start_operation("dn1_bench_tx_#{i}", true)
        faces = add_tx_faces(model, base_x, m, i)
        t1 = Dn1supBenchmark.monotonic
        model.commit_operation
        t2 = Dn1supBenchmark.monotonic
        ctx['modify'] << (t1 - t0)
        ctx['commits'] << (t2 - t1)
        ctx['val'] << "commit #{i}: грани не валидны после фиксации" unless faces.all?(&:valid?)

        # Убираем зафиксированные грани (вне замера), чтобы следующий цикл
        # начинался из того же состояния.
        model.start_operation('dn1_bench_tx_cleanup', true)
        model.entities.erase_entities(faces.select(&:valid?))
        model.commit_operation

        # Путь отмены: старт → изменение → abort.
        t3 = Dn1supBenchmark.monotonic
        model.start_operation("dn1_bench_tx_abort_#{i}", true)
        faces2 = add_tx_faces(model, base_x, m, i)
        t4 = Dn1supBenchmark.monotonic
        model.abort_operation
        t5 = Dn1supBenchmark.monotonic
        ctx['mod_aborts'] << (t4 - t3)
        ctx['aborts'] << (t5 - t4)
        ctx['val'] << "abort #{i}: грани пережили отмену" if faces2.any?(&:valid?)
        ctx['cycles'] << ((t2 - t0) + (t5 - t3))
      rescue StandardError => e
        ctx['diag'] << diag_hash(e)
        begin
          model.abort_operation
        rescue StandardError
          nil
        end
        ctx['stop'] = true # дальнейшие циклы бессмысленны
      end

      def add_tx_faces(model, base_x, m, salt)
        m.times.map do |k|
          x = base_x + (k % 200) * 150
          y = ((k / 200) + salt) * 150
          model.entities.add_face([x, y, 0], [x + 100, y, 0], [x + 100, y + 100, 0], [x, y + 100, 0])
        end.compact
      end

      # -- сцена textured: легаси-тесты материалов ----------------------------------------

      def tests_textured(model, params)
        tex = PngGen.cached_textures([256, 1024, 2048])

        # Загрузка текстур разных размеров в SketchUp (новый материал на итерацию).
        [256, 1024, 2048].each do |size|
          measure('api', "texture_load_#{size}", "Загрузка текстуры #{size}×#{size}",
                  'ms', params['iters'], entities: size * size, ops: 1,
                  params: { 'texture' => "#{size}x#{size}", 'source' => 'PNG из временной папки' }) do |i|
            mat = model.materials.add("dn1_tex_#{size}_#{i}")
            mat.texture = tex[size.to_s]
          end
        end

        faces = model.entities.grep(Sketchup::Face)
        apply_n = [params['tex_apply'], faces.size].min

        # Батч-назначение текстурного материала на грани.
        measure('api', 'apply_texture_batch', "Наложение текстуры на грани (батч #{apply_n})",
                'ms', 2, entities: apply_n, ops: apply_n,
                params: { 'batch' => apply_n }) do |i|
          mat = model.materials.add("dn1_apply_#{i}")
          mat.texture = tex[i.zero? ? '1024' : '256']
          faces.first(apply_n).each { |f| f.material = mat }
        end

        # Полная перекраска сцены на другую текстуру.
        measure('api', 'repaint_textured', "Перекраска всех граней (#{apply_n}) другой текстурой",
                'ms', 2, entities: apply_n, ops: apply_n,
                params: { 'batch' => apply_n }) do |i|
          mat = model.materials.add("dn1_repaint_#{i}")
          mat.texture = tex[i.zero? ? '256' : '2048']
          faces.first(apply_n).each { |f| f.material = mat }
        end

        # Батч цветных материалов (без текстур).
        measure('api', 'apply_color_batch', "Цветные материалы: назначение батчу граней (#{apply_n})",
                'ms', params['iters'], entities: apply_n, ops: apply_n,
                params: { 'batch' => apply_n }) do |i|
          cval = (i * 47) % 255
          mat = model.materials.add("dn1_color_#{i}")
          mat.color = Sketchup::Color.new(cval, (cval * 2) % 255, 255 - cval)
          faces.first(apply_n).each { |f| f.material = mat }
        end
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

      def scene_title(name)
        { 'basics' => 'базовые API', 'nested' => 'вложенные группы', 'components' => 'компоненты',
          'grid' => 'плотная сетка', 'textured' => 'текстурированные боксы' }.fetch(name, name)
      end

      def scene_params(name)
        p = @state['params']
        case name
        when 'nested' then { 'depth' => p['nested']['depth'], 'items' => p['nested']['items'] }
        when 'components' then p['components'].merge('targets' => p['targets'])
        when 'grid' then { 'n' => p['grid']['n'], 'expected_edges' => 2 * p['grid']['n'] * (p['grid']['n'] + 1) }
        when 'textured' then { 'boxes' => p['textured']['boxes'] }
        else {}
        end
      end

      def doc_params(path, size)
        { 'file' => File.basename(path.to_s), 'dir' => 'временная папка пользователя',
          'file_size_bytes' => size,
          'cache' => 'файловый кэш ОС тёплый; «холодный» запуск не заявляется' }
      end

      def build_doc_fixture(model, path, boxes)
        model.start_operation('DN1Sup Benchmark: doc fixture', true)
        defn = model.definitions.add('dn1_doc_fixture')
        boxes.times do |k|
          x = (k % 10) * 300
          y = (k / 10) * 300
          face = defn.entities.add_face([x, y, 0], [x + 200, y, 0], [x + 200, y + 200, 0], [x, y + 200, 0])
          face.pushpull(100)
        end
        ok = defn.save_copy(path)
        model.abort_operation
        raise "save_copy вернул #{ok.inspect}" unless ok && File.exist?(path)
      rescue Exception
        begin
          model.abort_operation
        rescue StandardError
          nil
        end
        raise
      end

      def set_active_path(model, path)
        model.active_path = path
      rescue StandardError
        model.active_path = nil if path.empty?
      end

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
        @state['log'] << "[#{Time.now.strftime('%H:%M:%S')}] #{msg}" if @state
        puts "[dn1sup_benchmark] #{msg}"
      end

      def deep_copy(obj)
        Marshal.load(Marshal.dump(obj))
      end
    end
  end

  # RUBY-01: фиксированная чистая Ruby-нагрузка (массивы, хеши, арифметика).
  # Детерминирована, без обращения к SketchUp API; объём операций зафиксирован
  # и записывается в результат.
  module RubyWorkload
    ARRAY_N = 20_000
    HASH_N = 20_000
    MATH_N = 200_000
    TOTAL_OPS = ARRAY_N * 4 + HASH_N * 2 + MATH_N

    class << self
      def spec
        { 'array_ops' => ARRAY_N * 4, 'hash_ops' => HASH_N * 2, 'math_ops' => MATH_N,
          'total_ops' => TOTAL_OPS }
      end

      def run
        # Массивы: построение, сортировка, преобразование, выборка.
        a = Array.new(ARRAY_N) { |i| (i * 2_654_435_761) % 1_000_003 }
        a.sort!
        a.map! { |x| (x * 2) % 999_983 }
        odd = a.select(&:odd?).size
        # Хеши: вставка и чтение по детерминированным ключам.
        h = {}
        HASH_N.times { |i| h[(i * 40_503) % 999_983] = i }
        hits = 0
        HASH_N.times { |i| hits += 1 if h.key?((i * 7_919) % 999_983) }
        # Арифметика: фиксированный цикл с плавающей точкой.
        acc = 0.0
        MATH_N.times { |j| acc = (acc + j * 0.5) % 1.0e9 }
        # «Поглощаем» результаты, чтобы RTL не выбросил работу.
        odd + hits + (acc > -1 ? 1 : 0)
      end
    end
  end
end
