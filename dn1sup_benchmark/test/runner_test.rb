# frozen_string_literal: true
# dn1sup_benchmark/test/runner_test.rb — методика раннера (без живого прогона).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  test 'PROFILES содержат quick и full' do
    assert(Dn1supBenchmark::Runner::PROFILES.key?('quick'), 'нет quick')
    assert(Dn1supBenchmark::Runner::PROFILES.key?('full'), 'нет full')
  end

  test 'steps: полный план с begin/scene/fps/finish' do
    steps = Dn1supBenchmark::Runner.steps('quick')
    kinds = steps.map { |s| s['kind'] }
    assert_equal('begin', kinds.first)
    assert_equal('finish', kinds.last)
    assert(kinds.count('scene') >= 4, "ожидали 4 сцены, получили #{kinds.count('scene')}")
    assert(kinds.count('fps') >= 4, "ожидали 4 FPS-шага, получили #{kinds.count('fps')}")
    scenes = steps.select { |s| s['kind'] == 'scene' }.map { |s| s['scene'] }
    assert_equal(%w[nested components grid textured], scenes, 'порядок сцен')
  end

  test 'steps: неизвестный профиль даёт ошибку' do
    assert_raises(ArgumentError) { Dn1supBenchmark::Runner.steps('mega') }
  end

  test 'median: нечётное, чётное, пустое' do
    r = Dn1supBenchmark::Runner
    assert_equal(2, r.median([3, 1, 2]))
    assert_equal(2.5, r.median([1, 2, 3, 4]))
    assert_nil(r.median([]))
  end

  test 'perform неизвестного шага не падает' do
    assert(Dn1supBenchmark::Runner.perform({ 'kind' => 'zzz' }).is_a?(String))
  end
end
