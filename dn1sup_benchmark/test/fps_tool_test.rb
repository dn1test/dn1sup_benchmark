# frozen_string_literal: true
# dn1sup_benchmark/test/fps_tool_test.rb — механика FPS-инструмента
# (без живого рендер-лупа: он проверяется реальным quick-прогоном).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  test 'FpsTool: начальное состояние' do
    tool = Dn1supBenchmark::FpsTool.new(1.5, true)
    assert(tool.orbit?, 'orbit должен быть включён')
    assert_nil(tool.result, 'результата до замера быть не должно')
    assert_nil(tool.stop_now, 'stop_now без activate должен вернуть nil')
  end

  test 'FpsTool: activate/deactivate не падают в SketchUp' do
    skip('вне SketchUp') unless defined?(Sketchup) && Sketchup.active_model
    tool = Dn1supBenchmark::FpsTool.new(0.2, false)
    view = Sketchup.active_model.active_view
    tool.activate
    tool.deactivate(view)
    assert_nil(tool.result, 'без draw результата нет')
  end

  test 'Runner: FPS без прогона корректно отклоняется' do
    Dn1supBenchmark::Runner.fps_stop_tool
    assert_equal('нет активного FPS-замера', Dn1supBenchmark::Runner.fps_collect)
  end

  test 'иерархия: вход/выход по active_path (smoke)' do
    skip('вне SketchUp: нет активной модели') unless defined?(Sketchup) && Sketchup.active_model
    model = Sketchup.active_model
    model.start_operation('dn1sup_benchmark test: hierarchy', true)
    begin
      info = Dn1supBenchmark::Scenes.build_nested(model, 3, 1)
      r = Dn1supBenchmark::Runner
      r.set_active_path(model, [info['path'][0]])
      assert_equal(1, model.active_path.size, 'должны войти на 1 уровень')
      r.leave_edit_context(model)
      assert(model.active_path.nil? || model.active_path.empty?, 'должны выйти из контекста')
    ensure
      model.abort_operation
    end
  end
end
