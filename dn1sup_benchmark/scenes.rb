# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/scenes.rb — детерминированные генераторы тестовых сцен
# (набор v4: моделирование, вьюпорт, волна, файл ~500 МБ).
#
# Всё строится только по формулам от индексов (без rand) — на любой машине
# и в любой версии SketchUp геометрия идентична, метрики сравнимы. Сцены
# строятся ВНУТРИ уже открытой undo-операции (её открывает Runner); Runner
# же делает entities.clear! + abort_operation.
#
# Лимит на компонентные сцены (~10 тыс. инстансов) — урок инцидента
# SU2027 (suite v2→3): сцена ~80 тыс. вложенных инстансов компонентов
# вешала вьюпорт на первом простое.
#
# Размеры задаются в миллиметрах через Numeric#mm (API внутри хранит дюймы).
# =============================================================================

module Dn1supBenchmark
  module Scenes
    module_function

    # --- diverse: сложная модель «как строит пользователь» ---------------------
    # Уникальные листовые компоненты (формульно разные размеры), сборки из
    # разных наборов листьев и сетка сборок: много вложений, групп и
    # компонентов, «все разные». Построение идёт пофазно (кусками): хелперы
    # ниже вызываются Runner'ом по одному определению/инстансу за единицу.

    # Листовое определение i: бокс с уникальными формульными размерами.
    def diverse_leaf_def(model, i)
      defn = model.definitions.add("dn1_leaf_#{i}")
      w = (80 + (i % 7) * 30).mm         # 80..260 мм
      d = (40 + ((i * 13) % 6) * 20).mm  # 40..140 мм
      h = (60 + ((i / 7) % 5) * 40).mm   # 60..220 мм
      face = defn.entities.add_face([0, 0, 0], [w, 0, 0], [w, d, 0], [0, d, 0])
      face.pushpull(h)
      defn
    end

    # Сборочное определение j: leaves листьев из разных мест списка
    # (набор листьев внутри каждой сборки свой).
    def diverse_asm_def(model, leaf_defs, j, leaves)
      defn = model.definitions.add("dn1_asm_#{j}")
      leaves.times do |k|
        leaf = leaf_defs[(j * leaves + k * 3 + 1) % leaf_defs.size]
        x = (k % 2) * 300.mm
        y = (k / 2) * 300.mm
        z = (k * 40).mm
        defn.entities.add_instance(leaf, Geom::Transformation.new([x, y, z]))
      end
      defn
    end

    # Инстанс сборки в клетке i сетки grid×grid.
    def diverse_top_instance(model, asm_defs, grid, i)
      defn = asm_defs[i % asm_defs.size]
      step = 700.mm
      x = (i % grid) * step
      y = (i / grid) * step
      model.entities.add_instance(defn, Geom::Transformation.new([x, y, 0]))
    end

    # Синхронная сборка целиком (юнит-тесты; Runner строит кусочками).
    def build_diverse(model, opts = {})
      grid = opts.fetch('grid', 8)
      leaves = opts.fetch('leaves', 2)
      leaf_defs = opts.fetch('leaf_defs', 4).times.map { |i| diverse_leaf_def(model, i) }
      asm_defs = opts.fetch('asm_defs', 2).times.map { |j| diverse_asm_def(model, leaf_defs, j, leaves) }
      instances = (grid * grid).times.map { |i| diverse_top_instance(model, asm_defs, grid, i) }
      { 'entities' => grid * grid * leaves, 'instances' => instances,
        'leaf_defs' => leaf_defs, 'grid' => grid, 'leaves' => leaves }
    end

    # --- poly: многоугольная нагрузка (сетка цилиндров) ------------------------
    # Один цилиндр с segments сегментами; рендер-геометрия ≈ n²×(2×segments+2)
    # треугольников при скромном числе сущностей.

    def poly_cylinder_def(model, segments)
      defn = model.definitions.add('dn1_poly_cyl')
      circle = defn.entities.add_circle([0, 0, 0], [0, 0, 1], 50.mm, segments)
      face = defn.entities.add_face(curve_edges(circle))
      face.pushpull(120.mm)
      defn
    end

    # add_circle/add_arc до SU2023 возвращали ArcCurve, начиная с SU2023 —
    # Array рёбер; единая нормализация.
    def curve_edges(curve)
      curve.is_a?(Array) ? curve : curve.edges
    end

    def poly_instance(model, defn, n, i)
      step = 130.mm
      x = (i % n) * step
      y = (i / n) * step
      model.entities.add_instance(defn, Geom::Transformation.new([x, y, 0]))
    end

    def build_poly(model, n, segments = 36)
      defn = poly_cylinder_def(model, segments)
      (n * n).times { |i| poly_instance(model, defn, n, i) }
      { 'entities' => n * n, 'n' => n, 'segments' => segments,
        'triangles' => n * n * (2 * segments + 2) }
    end

    # --- wave: полотно кубов 100×100×100 мм -------------------------------------
    CUBE_MM = 100.0

    def wave_cube_def(model)
      defn = model.definitions.add('dn1_wave_cube')
      face = defn.entities.add_face([0, 0, 0], [CUBE_MM.mm, 0, 0],
                                    [CUBE_MM.mm, CUBE_MM.mm, 0], [0, CUBE_MM.mm, 0])
      face.pushpull(CUBE_MM.mm)
      defn
    end

    # Инстанс i полотна grid×grid (координаты — в мм, центрировано вокруг 0).
    # Возвращает [инстанс, x_мм, y_мм].
    def wave_cube(model, defn, grid, i)
      x = (i % grid) * CUBE_MM - (grid - 1) * CUBE_MM / 2.0
      y = (i / grid) * CUBE_MM - (grid - 1) * CUBE_MM / 2.0
      inst = model.entities.add_instance(defn, Geom::Transformation.new([x.mm, y.mm, 0]))
      [inst, x, y]
    end

    def build_wave(model, grid)
      defn = wave_cube_def(model)
      instances = []
      positions = []
      (grid * grid).times do |i|
        inst, x, y = wave_cube(model, defn, grid, i)
        instances << inst
        positions << [x, y]
      end
      { 'entities' => grid * grid, 'instances' => instances,
        'positions' => positions, 'grid' => grid }
    end

    # --- storage: уникальная геометрия тяжёлого файла ---------------------------
    # Бокс k с формульно разными размерами в 3D-сетке: уникальные рёбра не
    # сжимаются инстансингом, файл растёт линейно. Пишется в определение
    # dn1_storage (без инстансов — вьюпорт не нагружается).

    def storage_box(defn, k)
      w = (60 + (k % 9) * 20).mm
      h = (40 + ((k / 9) % 7) * 15).mm
      x = (k % 40) * 300.mm
      y = ((k / 40) % 40) * 300.mm
      z = ((k / 1600) % 40) * 300.mm
      face = defn.entities.add_face([x, y, z], [x + w, y, z],
                                    [x + w, y + w, z], [x, y + w, z])
      face.pushpull(h)
      true
    end

    def build_storage(defn, boxes)
      boxes.times { |k| storage_box(defn, k) }
      { 'entities' => defn.entities.size, 'boxes' => boxes }
    end

    # Переключение страниц (Pages#selected_page=) НЕ автоматизируется:
    # применение страницы внутри открытой undo-операции фиксирует
    # транзакцию ядра, и последующий abort уже не откатывает контент
    # (инцидент 2026-10-28, SU2027) — см. fps_tool.rb.
  end
end
