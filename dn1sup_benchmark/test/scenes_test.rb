# frozen_string_literal: true
# dn1sup_benchmark/test/scenes_test.rb — smoke-тесты генераторов сцен.
# Всё строится внутри undo-операции и откатывается: модель не меняется.

require_relative 'test_helper'

module Dn1supBenchmark::Test
  SC = Dn1supBenchmark::Scenes

  def self.smoke_scene(name)
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.active_model
    model = Sketchup.active_model
    before = model.entities.size
    model.start_operation("dn1sup_benchmark test: #{name}", true)
    begin
      info = yield(model)
      assert(info['entities'].to_i >= 0, "сцена #{name}: entities должен быть счётчиком")
      info
    ensure
      model.abort_operation
      # Регрессия отката: сцена не имеет права менять модель (инцидент
      # 2026-10-28 — page-switch внутри undo-операции ломал откат).
      assert_equal(before, model.entities.size, "сцена #{name}: модель изменилась после отката")
    end
  end

  test 'diverse: уникальные компоненты, сборки, сетка' do
    smoke_scene('diverse') do |model|
      info = SC.build_diverse(model, { 'grid' => 4, 'leaves' => 2, 'leaf_defs' => 5, 'asm_defs' => 3 })
      # Проверки — ДО отката операции: после abort определения удаляются.
      assert_equal(4 * 4 * 2, info['entities'], '4² сборок × 2 листа = 32 инстанса')
      assert_equal(5, info['leaf_defs'].size, 'уникальных листовых определений')
      names = info['leaf_defs'].map(&:name)
      assert_equal(names.uniq.size, names.size, 'определения должны быть разными')
      info
    end
  end

  test 'poly: сетка цилиндров' do
    info = smoke_scene('poly') do |model|
      SC.build_poly(model, 5, 24)
    end
    assert_equal(25, info['entities'], '5×5 = 25 инстансов')
    assert_equal(25 * (2 * 24 + 2), info['triangles'], 'оценка треугольников')
  end

  test 'wave: полотно кубов 100×100×100 мм' do
    info = smoke_scene('wave') do |model|
      SC.build_wave(model, 4)
    end
    assert_equal(16, info['entities'], '4×4 = 16 кубов')
    assert_equal(16, info['instances'].size)
    assert_equal(16, info['positions'].size)
    # Центрирование: сумма координат по каждой оси = 0.
    sx = info['positions'].sum { |x, _y| x }
    assert_equal(0.0, sx, 'полотно центрировано по X')
  end

  test 'storage_box: уникальные тела в определении' do
    info = smoke_scene('storage') do |model|
      defn = model.definitions.add('dn1_test_storage')
      SC.build_storage(defn, 3)
    end
    assert_equal(3, info['boxes'])
    assert(info['entities'] >= 18, '3 бокса ≥ 18 граней')
  end

  test 'сцены детерминированы: два построения дают одно число сущностей' do
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.active_model
    model = Sketchup.active_model
    counts = 2.times.map do
      model.start_operation('dn1sup_benchmark test: determinism', true)
      begin
        SC.build_poly(model, 5)['entities']
      ensure
        model.abort_operation
      end
    end
    assert_equal(counts[0], counts[1], 'повторные построения разошлись')
  end
end
