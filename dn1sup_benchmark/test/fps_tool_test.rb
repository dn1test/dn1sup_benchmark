# frozen_string_literal: true
# dn1sup_benchmark/test/fps_tool_test.rb — механика FPS-инструмента
# (без живого рендер-лупа: он проверяется реальным small-прогоном).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  test 'FpsTool: начальное состояние' do
    tool = Dn1supBenchmark::FpsTool.new(1.5, 'orbit')
    assert(tool.orbit?, 'orbit должен быть включён')
    assert_nil(tool.result, 'результата до замера быть не должно')
    assert_nil(tool.stop_now, 'stop_now без activate должен вернуть nil')
  end

  test 'FpsTool: режимы нормализуются' do
    f = Dn1supBenchmark::FpsTool
    assert_equal('orbit', f.new(1, true).mode, 'легаси true → orbit')
    assert_equal('static', f.new(1, false).mode, 'легаси false → static')
    assert_equal('static', f.new(1, nil).mode)
    %w[static orbit pan zoom].each do |m|
      assert_equal(m, f.new(1, m).mode, "режим #{m}")
    end
    assert_equal('static', f.new(1, 'чушь').mode, 'неизвестный режим → static')
    assert_equal('static', f.new(1, 'pages').mode, 'page-switch удалён (инцидент 2026-10-28) → static')
  end

  test 'FpsTool: activate/deactivate не падают в SketchUp' do
    skip('вне SketchUp') unless defined?(Sketchup) && Sketchup.active_model
    tool = Dn1supBenchmark::FpsTool.new(0.2, 'static')
    view = Sketchup.active_model.active_view
    tool.activate
    tool.deactivate(view)
    assert_nil(tool.result, 'без draw результата нет')
  end

  test 'Runner: FPS без прогона корректно отклоняется' do
    Dn1supBenchmark::Runner.fps_stop_tool
    assert_equal('нет активного FPS-замера', Dn1supBenchmark::Runner.fps_collect)
  end
end
