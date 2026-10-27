# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/runner.rb — методика и выполнение бенчмарка.
#
# Прогон = последовательность ШАГОВ (Runner.steps): :begin → :scene (строят
# сцену и выполняют синхронные тесты) → :fps (асинхронный FPS-метр) → :finish
# (отчёт). Один и тот же план шагов исполняется двумя способами:
#   • из меню — секвенсор на UI.start_timer (main.rb): UI не блокируется;
#   • через мост — пошагово отдельными eval (километр 60 с на eval не лимит),
#     между :fps и сбором результата клиент выдерживает паузу сам.
#
# Сцена живёт внутри одной undo-операции: start_operation → build → тесты →
# clear! + abort_operation (проверенный паттерн). Модель пользователя после
# прогона возвращается к исходному состоянию.
#
# Замеры: только Process.clock_gettime(CLOCK_MONOTONIC); медиана/min/max;
# GC.start между тестами; ошибка теста не роняет прогон (попадает в отчёт).
# =============================================================================

module Dn1supBenchmark
  module Runner
    PROFILES = {
      'quick' => {
        'nested' => { 'depth' => 6, 'items' => 4 },
        'components' => { 'defs' => 24, 'assemblies' => 8, 'per_assembly' => 5, 'grid' => 8 },
        'grid' => { 'n' => 25 },
        'textured' => { 'boxes' => 24 },
        'fps_s' => 1.5, 'iters' => 3,
        'pushpull' => 8, 'move' => 10, 'add_faces' => 8, 'tex_apply' => 60
      },
      'full' => {
        'nested' => { 'depth' => 6, 'items' => 12 },
        'components' => { 'defs' => 40, 'assemblies' => 10, 'per_assembly' => 8, 'grid' => 18 },
        'grid' => { 'n' => 80 },
        'textured' => { 'boxes' => 120 },
        'fps_s' => 4.0, 'iters' => 5,
        'pushpull' => 40, 'move' => 40, 'add_faces' => 20, 'tex_apply' => 400
      }
    }.freeze

    GROUP_TITLES = {
      'scene_gen' => 'Построение сцен (ядро геометрии)',
      'viewport' => 'Вьюпорт (FPS рендера)',
      'hierarchy' => 'Навигация по иерархии',
      'editing' => 'Редактирование',
      'textures' => 'Материалы и текстуры'
    }.freeze

    class << self
      attr_reader :tool

      # -- план прогона ----------------------------------------------------------

      def steps(profile)
        raise ArgumentError, "неизвестный профиль: #{profile}" unless PROFILES.key?(profile)

        [
          { 'kind' => 'begin', 'profile' => profile, 'label' => 'Инициализация' },
          { 'kind' => 'scene', 'scene' => 'nested', 'label' => 'Сцена: вложенные группы (иерархия)' },
          { 'kind' => 'scene', 'scene' => 'components', 'label' => 'Сцена: компоненты (обход, правки)' },
          { 'kind' => 'fps', 'id' => 'fps_components_static', 'orbit' => false,
            'name' => 'FPS: компоненты, статичный вид' },
          { 'kind' => 'scene', 'scene' => 'grid', 'label' => 'Сцена: плотная сетка (pushpull, zoom)' },
          { 'kind' => 'fps', 'id' => 'fps_grid_static', 'orbit' => false,
            'name' => 'FPS: сетка, статичный вид' },
          { 'kind' => 'fps', 'id' => 'fps_grid_orbit', 'orbit' => true,
            'name' => 'FPS: сетка, орбита' },
          { 'kind' => 'scene', 'scene' => 'textured', 'label' => 'Сцена: текстуры (назначение, перекраска)' },
          { 'kind' => 'fps', 'id' => 'fps_textured_static', 'orbit' => false,
            'name' => 'FPS: текстуры, статичный вид' },
          { 'kind' => 'finish', 'label' => 'Отчёт' }
        ]
      end

      # -- исполнение шагов ------------------------------------------------------

      def perform(step)
        case step['kind']
        when 'begin'  then begin_run(step['profile'])
        when 'scene'  then open_scene(step['scene'])
        when 'fps'    then fps_start(step)
        when 'finish' then finish_run
        else "неизвестный шаг: #{step['kind']}"
        end
      end

      def begin_run(profile)
        raise ArgumentError, "неизвестный профиль: #{profile}" unless PROFILES.key?(profile)

        close_scene # страховка: не должно быть висящей операции
        @state = {
          'profile' => profile,
          'params' => PROFILES[profile],
          'meta' => context(profile),
          'results' => [],
          'scene' => nil,
          'scene_info' => nil,
          'log' => []
        }
        PngGen.cached_textures([256, 1024, 2048]) # генерация вне замеров
        log_line("прогон начат (#{profile})")
        'ok'
      end

      def open_scene(name)
        close_scene
        model = Sketchup.active_model
        model.start_operation("DN1Sup Benchmark: #{name}", true)
        @state['scene'] = name
        info = nil
        t0 = Dn1supBenchmark.monotonic
        case name
        when 'nested'
          p = @state['params']['nested']
          info = Scenes.build_nested(model, p['depth'], p['items'])
        when 'components'
          p = @state['params']['components']
          info = Scenes.build_components(model, p['defs'], p['assemblies'],
                                         p['per_assembly'], p['grid'])
        when 'grid'
          p = @state['params']['grid']
          info = Scenes.build_grid(model, p['n'])
        when 'textured'
          p = @state['params']['textured']
          info = Scenes.build_textured(model, p['boxes'])
        else
          raise ArgumentError, "неизвестная сцена: #{name}"
        end
        dt = Dn1supBenchmark.monotonic - t0
        @state['scene_info'] = info
        GC.start
        add_result('scene_gen', "scene_gen_#{name}", "Построение: #{scene_title(name)}",
                   'ms', [dt], info['entities'])
        log_line("сцена #{name}: #{(dt * 1000).round} мс, entities=#{info['entities']}")

        send("tests_#{name}", model, @state['params'])
        "ok: #{name} за #{(dt * 1000).round} мс (entities=#{info['entities']})"
      end

      def close_scene
        return if @state.nil?
        return if @state['scene'].nil?

        model = Sketchup.active_model
        leave_edit_context(model)
        begin
          model.entities.clear!
          model.abort_operation
        rescue StandardError => e
          log_line("close_scene: #{e.class}: #{e.message}")
        end
        @state['scene'] = nil
        @state['scene_info'] = nil
        GC.start
        nil
      end

      # -- FPS (асинхронно: start → кадры идут в UI-потоке → collect) -----------

      def fps_start(step)
        return 'нет активного прогона' if @state.nil?
        return 'FPS только на открытой сцене' if @state['scene'].nil?

        fps_stop_tool # страховка от забытого инструмента
        view = Sketchup.active_model.active_view
        view.zoom_extents
        @tool = FpsTool.new(@state['params']['fps_s'], step['orbit'])
        @fps_step = step
        Sketchup.active_model.select_tool(@tool)
        "started: #{step['id']} (#{step['orbit'] ? 'orbit' : 'static'}, #{@state['params']['fps_s']}s)"
      end

      def fps_ready?
        !@tool.nil? && !@tool.result.nil?
      end

      def fps_collect
        return 'нет активного FPS-замера' if @tool.nil?

        result = @tool.result || @tool.stop_now
        fps_stop_tool
        if result.nil? || result['frames'].to_i.zero?
          add_error('viewport', @fps_step['id'], @fps_step['name'], 'кадры не отрисовались')
          return 'error: frames=0'
        end
        add_result('viewport', @fps_step['id'], @fps_step['name'], 'fps',
                   [result['fps']], result['frames'], true,
                   'frames' => result['frames'], 'elapsed_s' => result['elapsed_s'],
                   'mode' => result['mode'])
        log_line("#{@fps_step['id']}: #{result['fps']} fps (#{result['frames']} кадров)")
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

      # -- финал ------------------------------------------------------------------

      def finish_run
        return 'нет активного прогона' if @state.nil?

        fps_stop_tool
        close_scene
        data = run_data
        @state = nil
        paths = Report.save_run(data)
        Dn1supBenchmark.last_report = paths['html']
        { 'status' => 'ok', 'json' => paths['json'], 'html' => paths['html'],
          'tests' => data['results'].size,
          'errors' => data['results'].count { |r| r['error'] } }
      end

      def run_data
        return nil if @state.nil?

        { 'meta' => @state['meta'], 'results' => @state['results'].dup,
          'log' => @state['log'].dup }
      end

      # -- синхронные тесты по сценам ---------------------------------------------

      def tests_nested(model, params)
        path = @state['scene_info']['path']

        # Полный цикл: спуск до дна иерархии, подъём обратно. Одна итерация =
        # один цикл. Синхронный вызов active_path= — само ядро навигации.
        measure('hierarchy_open_close', 'hierarchy', 'Вход/выход: полный спуск-подъём (6 уровней)',
                'ms', params['iters'], path.size) do |_i|
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
        add_result('hierarchy', 'hierarchy_step_dive', 'Пошаговый спуск по уровням (медиана шага)',
                   'ms', times, path.size)
      end

      def tests_components(model, params)
        # Обход иерархии: суммарный подсчёт инстансов по всем определениям.
        measure('traverse_tree', 'hierarchy', 'Обход дерева определений/инстансов',
                'ms', params['iters'], @state['scene_info']['total_instances']) do |_i|
          count = 0
          model.definitions.each { |d| count += d.instances.size }
          raise 'обход насчитал 0' if count.zero?
        end

        # Перемещение верхних инстансов (round-trip туда-обратно) — правка,
        # на которую вьюпорт отвечает пересчётом.
        tops = model.entities.grep(Sketchup::ComponentInstance).first(params['move'])
        measure('move_instances', 'editing', "Перемещение инстансов (батч #{tops.size}, round-trip)",
                'ms', params['iters'], tops.size) do |i|
          dir = i.even? ? 1 : -1
          tr = Geom::Transformation.new(Geom::Vector3d.new(50 * dir, 0, 0))
          tops.each { |inst| inst.transform!(tr) }
        end

        # Правка определения: все инстансы пересчитываются. Добавляем и стираем
        # грани в листовом определении.
        defn = model.definitions['dn1_leaf_0']
        raise 'dn1_leaf_0 не найден' if defn.nil?

        measure('editing_modify_definition', 'editing',
                "Правка определения (add+erase #{params['add_faces']} граней → пересчёт инстансов)",
                'ms', params['iters'], params['add_faces']) do |_i|
          faces = []
          params['add_faces'].times do |k|
            x = 5000 + k * 120
            faces << defn.entities.add_face([x, 0, 0], [x + 100, 0, 0],
                                            [x + 100, 100, 0], [x, 100, 0])
          end
          defn.entities.erase_entities(faces)
        end
      end

      def tests_grid(model, params)
        n = params['pushpull']
        # Ссылки на грани НЕ переживают push/pull (ядро пересоздаёт геометрию),
        # поэтому батч собирается заново на каждой итерации.
        measure('pushpull_batch', 'editing', "Push/pull батча граней сетки (до #{n} шт.)",
                'ms', params['iters'], n) do |i|
          faces = model.entities.grep(Sketchup::Face).select(&:valid?)
          h = i.even? ? 40 : -40
          faces.first(n).each { |f| f.pushpull(h) }
        end

        view = model.active_view
        measure('zoom_extents', 'viewport', 'Zoom Extents на плотной сцене',
                'ms', params['iters'], model.entities.grep(Sketchup::Face).size) do |_i|
          view.zoom_extents
        end
      end

      def tests_textured(model, params)
        tex = PngGen.cached_textures([256, 1024, 2048])

        # Загрузка текстур разных размеров в SketchUp (новый материал на итерацию).
        [256, 1024, 2048].each do |size|
          measure("texture_load_#{size}", 'textures', "Загрузка текстуры #{size}×#{size}",
                  'ms', params['iters'], size * size) do |i|
            mat = model.materials.add("dn1_tex_#{size}_#{i}")
            mat.texture = tex[size.to_s]
          end
        end

        faces = model.entities.grep(Sketchup::Face)
        apply_n = [params['tex_apply'], faces.size].min

        # Батч-назначение текстурного материала на грани.
        measure('apply_texture_batch', 'textures',
                "Наложение текстуры на грани (батч #{apply_n})",
                'ms', 2, apply_n) do |i|
          mat = model.materials.add("dn1_apply_#{i}")
          mat.texture = tex[i.zero? ? '1024' : '256']
          faces.first(apply_n).each { |f| f.material = mat }
        end

        # Полная перекраска сцены на другую текстуру.
        measure('repaint_textured', 'textures', "Перекраска всех граней (#{apply_n}) другой текстурой",
                'ms', 2, apply_n) do |i|
          mat = model.materials.add("dn1_repaint_#{i}")
          mat.texture = tex[i.zero? ? '256' : '2048']
          faces.first(apply_n).each { |f| f.material = mat }
        end

        # Батч цветных материалов (без текстур).
        measure('apply_color_batch', 'textures', "Цветные материалы: назначение батчу граней (#{apply_n})",
                'ms', params['iters'], apply_n) do |i|
          cval = (i * 47) % 255
          mat = model.materials.add("dn1_color_#{i}")
          mat.color = Sketchup::Color.new(cval, (cval * 2) % 255, 255 - cval)
          faces.first(apply_n).each { |f| f.material = mat }
        end
      end

      # -- измерительный каркас -----------------------------------------------------

      def measure(id, group, name, unit, iters, entities, higher = false, extra = nil, &blk)
        times = []
        error = nil
        begin
          iters.times do |i|
            t0 = Dn1supBenchmark.monotonic
            blk.call(i)
            times << Dn1supBenchmark.monotonic - t0
          end
          GC.start
        rescue StandardError => e
          error = "#{e.class}: #{e.message}"
          log_line("#{id}: #{error}")
        end
        if error && times.empty?
          add_error(group, id, name, error)
        else
          add_result(group, id, name, unit, times, entities, higher, extra, error)
        end
      end

      def add_result(group, id, name, unit, times, entities = nil,
                     higher = false, extra = nil, error = nil)
        rec = {
          'group' => group, 'id' => id, 'name' => name, 'unit' => unit,
          'higher_is_better' => higher,
          'times_ms' => times.map { |t| (t * 1000).round(1) },
          'entities' => entities, 'error' => error
        }
        rec.merge!(extra) if extra
        vals = if unit == 'fps'
                 times
               else
                 rec['times_ms']
               end
        rec['median'] = median(vals)
        rec['min'] = vals.min
        rec['max'] = vals.max
        rec['value'] = rec['median']
        @state['results'] << rec if @state
        rec
      end

      def add_error(group, id, name, error)
        rec = { 'group' => group, 'id' => id, 'name' => name, 'unit' => nil,
                'higher_is_better' => false, 'times_ms' => [], 'entities' => nil,
                'error' => error, 'median' => nil, 'min' => nil, 'max' => nil,
                'value' => nil }
        @state['results'] << rec if @state
        rec
      end

      def median(values)
        return nil if values.nil? || values.empty?

        s = values.sort
        n = s.size
        n.odd? ? s[n / 2] : ((s[n / 2 - 1] + s[n / 2]) / 2.0).round(2)
      end

      # -- контекст и утилиты ---------------------------------------------------------

      def context(profile)
        exts = 0
        Sketchup.extensions.each { |e| exts += 1 if e.loaded? }
        {
          'extension_version' => Dn1supBenchmark::VERSION,
          'profile' => profile,
          'sketchup_version' => Sketchup.version.to_s,
          'version_number' => Sketchup.version_number.to_i,
          'ruby_version' => RUBY_VERSION,
          'platform' => RUBY_PLATFORM,
          'cpu' => ENV['PROCESSOR_IDENTIFIER'].to_s,
          'cores' => ENV['NUMBER_OF_PROCESSORS'].to_i,
          'extensions_loaded' => exts,
          'started_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
        }
      end

      def scene_title(name)
        { 'nested' => 'вложенные группы', 'components' => 'компоненты',
          'grid' => 'плотная сетка', 'textured' => 'текстурированные боксы' }.fetch(name, name)
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
    end
  end
end
