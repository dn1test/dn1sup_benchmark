# frozen_string_literal: true
# =============================================================================
# dn1sup_benchmark/test/main_test.rb — тесты расширения «DN1Sup Benchmark».
# Запуск: внутри SketchUp через ext_test (MCP sketchup-dev) или меню
# «Тесты»; локально — ruby test/main_test.rb (модельные тесты уйдут в skip).
# =============================================================================

require_relative 'test_helper'

module Dn1supBenchmark::Test
  test 'версия расширения задана' do
    assert_equal '0.6.0', Dn1supBenchmark::VERSION
  end

  test 'модуль отвечает на программные команды' do
    assert(Dn1supBenchmark.respond_to?(:benchmark_steps), 'нет benchmark_steps')
    assert(Dn1supBenchmark.respond_to?(:benchmark_plan), 'нет benchmark_plan')
    assert(Dn1supBenchmark.respond_to?(:benchmark_perform), 'нет benchmark_perform')
    assert(Dn1supBenchmark.respond_to?(:benchmark_cancel), 'нет benchmark_cancel')
    assert(Dn1supBenchmark.respond_to?(:benchmark_last_run), 'нет benchmark_last_run')
    assert(Dn1supBenchmark.respond_to?(:benchmark_runs), 'нет benchmark_runs')
    assert(Dn1supBenchmark.respond_to?(:unload!), 'нет unload! (нужен для ext_reload)')
  end

  test 'PLUG_ROOT указывает на папку расширения' do
    assert(File.directory?(Dn1supBenchmark::PLUG_ROOT), Dn1supBenchmark::PLUG_ROOT)
    assert(File.exist?(File.join(Dn1supBenchmark::PLUG_ROOT, 'main.rb')), 'нет main.rb рядом')
  end

  test 'monotonic не убывает' do
    a = Dn1supBenchmark.monotonic
    b = Dn1supBenchmark.monotonic
    assert(b >= a, "ожидали b >= a, получили #{a} → #{b}")
  end

  test 'unload! возвращает true' do
    assert_equal(true, Dn1supBenchmark.unload!)
  end
end
