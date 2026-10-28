# frozen_string_literal: true
# dn1sup_benchmark/test/scenes_test.rb — smoke-тесты генераторов сцен.
# Всё строится внутри undo-операции и откатывается: модель не меняется.

require_relative 'test_helper'

module Dn1supBenchmark::Test
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

  test 'nested: цепочка вложенных групп' do
    info = self.smoke_scene('nested') do |model|
      Dn1supBenchmark::Scenes.build_nested(model, 4, 2)
    end
    assert_equal(4, info['path'].size, 'глубина цепочки')
  end

  test 'grid: сетка смежных граней' do
    info = self.smoke_scene('grid') do |model|
      Dn1supBenchmark::Scenes.build_grid(model, 6)
    end
    assert_equal(36, info['faces'], '6×6 = 36 граней')
  end

  test 'textured: боксы под раскраску' do
    info = self.smoke_scene('textured') do |model|
      Dn1supBenchmark::Scenes.build_textured(model, 5)
    end
    assert_equal(5, info['boxes'], '5 боксов')
    assert_equal(30, info['entities'], '5 боксов × 6 граней')
  end

  test 'grid_row: одна строка даёт n граней' do
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.active_model
    model = Sketchup.active_model
    model.start_operation('dn1sup_benchmark test: grid_row', true)
    begin
      before = model.entities.grep(Sketchup::Face).size
      Dn1supBenchmark::Scenes.grid_row(model, 5, 2)
      assert_equal(5, model.entities.grep(Sketchup::Face).size - before, '5 граней в строке')
    ensure
      model.abort_operation
    end
  end

  test 'сцены детерминированы: два построения дают одно число сущностей' do
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.active_model
    model = Sketchup.active_model
    counts = 2.times.map do
      model.start_operation('dn1sup_benchmark test: determinism', true)
      begin
        Dn1supBenchmark::Scenes.build_grid(model, 5)['faces']
      ensure
        model.abort_operation
      end
    end
    assert_equal(counts[0], counts[1], 'повторные построения разошлись')
  end
end
