# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/scenes.rb — детерминированные генераторы тестовых сцен.
#
# Все сцены строятся только по формулам от индексов (без rand) — на любой
# машине и в любой версии SketchUp геометрия идентична, поэтому метрики
# разных версий сравнимы. Сцены строятся ВНУТРИ уже открытой undo-операции
# (её открывает Runner); Runner же делает entities.clear! + abort_operation.
#
# Каждый build_* возвращает хеш с полезными для тестов ссылками
# (путь вложенных групп, число сущностей и т.п.).
# =============================================================================

module Dn1supBenchmark
  module Scenes
    module_function

    # --- nested: цепочка вложенных групп глубиной depth ------------------------
    # На каждом уровне items граней со смещением по глубине уровня.
    # Возвращает { 'path' => [g1, g2, ...], 'entities' => n }.
    def build_nested(model, depth, items)
      path = []
      container = nil
      count = 0
      depth.times do |d|
        ents = container.nil? ? model.entities : container.entities
        g = ents.add_group
        g.name = "lvl#{d + 1}"
        items.times do |i|
          x = (i % 4) * 150
          y = ((i / 4) % 4) * 150
          z = d * 40
          g.entities.add_face([x, y, z], [x + 100, y, z],
                              [x + 100, y + 100, z], [x, y + 100, z])
          count += 1
        end
        path << g
        container = g
      end
      { 'path' => path, 'entities' => count, 'depth' => depth }
    end

    # --- components: лес определений/сборок/инстансов --------------------------
    # defs листовых определений (боксы по 12 граней), assemblies сборок
    # (каждая = per_assembly инстансов листовых), сверху сетка grid×grid
    # инстансов сборок. Возвращает счётчики для traverse/тестов.
    #
    # Построение разложено на пофазные хелперы — их же использует кусочный
    # движок Runner (тяжёлые сцены не должны блокировать UI-поток надолго).
    def build_components(model, defs_n, assemblies_n, per_assembly, grid_n)
      leaf_defs = components_leaf_defs(model, 0, defs_n, defs_n)
      asm_defs = components_asm_defs(model, leaf_defs, 0, assemblies_n, assemblies_n, per_assembly, defs_n)
      components_top(model, asm_defs, 0, grid_n * grid_n, grid_n, assemblies_n)
      top = grid_n * grid_n
      { 'entities' => top + assemblies_n * per_assembly,
        'top_instances' => top,
        'leaf_defs' => defs_n, 'asm_defs' => assemblies_n,
        'total_instances' => top + assemblies_n * per_assembly }
    end

    # Фаза 1: листовые определения [from, to).
    def components_leaf_defs(model, from, to, defs_n)
      from.upto(to - 1).map do |i|
        defn = model.definitions.add("dn1_leaf_#{i}")
        w = 80 + (i % 5) * 30
        h = 60 + ((i * 7) % 4) * 25
        face = defn.entities.add_face([0, 0, 0], [w, 0, 0], [w, w, 0], [0, w, 0])
        face.pushpull(h)
        defn
      end
    end

    # Фаза 2: определения сборок [from, to).
    def components_asm_defs(model, leaf_defs, from, to, assemblies_n, per_assembly, defs_n)
      from.upto(to - 1).map do |a|
        defn = model.definitions.add("dn1_asm_#{a}")
        per_assembly.times do |k|
          tr = Geom::Transformation.new([((k % 3) * 250), (((k / 3) % 3) * 250), 0])
          defn.entities.add_instance(leaf_defs[(a * per_assembly + k) % defs_n], tr)
        end
        defn
      end
    end

    # Фаза 3: верхние инстансы [from, to) (общее = grid_n²).
    def components_top(model, asm_defs, from, to, grid_n, assemblies_n)
      step = 900
      from.upto(to - 1).each do |k|
        r = k / grid_n
        c = k % grid_n
        tr = Geom::Transformation.new([c * step, r * step, 0])
        model.entities.add_instance(asm_defs[k % assemblies_n], tr)
      end
    end

    # --- grid: плотная сетка смежных квадратов n×n ------------------------------
    def build_grid(model, n)
      n.times { |i| grid_row(model, n, i) }
      { 'entities' => n * n, 'n' => n, 'faces' => n * n }
    end

    # Одна строка i сетки (кусок построения).
    def grid_row(model, n, i)
      step = 100
      x0 = i * step
      n.times do |j|
        y0 = j * step
        model.entities.add_face([x0, y0, 0], [x0 + step, y0, 0],
                                [x0 + step, y0 + step, 0], [x0, y0 + step, 0])
      end
    end

    # --- textured: боксы под раскраску текстурными материалами -----------------
    # Материалы НЕ назначаются здесь — это делают текстурные тесты.
    def build_textured(model, boxes_n)
      boxes_n.times { |i| textured_box(model, boxes_n, i) }
      { 'entities' => boxes_n * 6, 'boxes' => boxes_n }
    end

    # Один бокс i (кусок построения).
    def textured_box(model, boxes_n, i)
      side = 120
      per_row = Math.sqrt(boxes_n).ceil
      per_row = 1 if per_row < 1
      x = (i % per_row) * (side * 2)
      y = ((i / per_row) % per_row) * (side * 2)
      h = 60 + ((i * 13) % 5) * 30
      face = model.entities.add_face([x, y, 0], [x + side, y, 0],
                                     [x + side, y + side, 0], [x, y + side, 0])
      face.pushpull(h)
    end

    # Генератор страниц (build_pages) удалён: автоматическое переключение
    # страниц внутри undo-операции небезопасно (инцидент 2026-10-28, SU2027) —
    # см. fps_tool.rb и README.
  end
end
