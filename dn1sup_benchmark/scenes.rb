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
    # Сцена components (build_components и пофазные хелперы) удалена (suite
    # v3): на SU2027 вьюпорт зависает на простое после построения сцены
    # ~80 000 вложенных инстансов — см. CHANGELOG 0.4.0 и runner.rb.
  end
end
