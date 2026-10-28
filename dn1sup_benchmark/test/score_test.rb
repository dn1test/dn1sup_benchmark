# frozen_string_literal: true
# dn1sup_benchmark/test/score_test.rb — необязательный общий балл
# (Geekbench-стиль): формула, веса, статусы, база.

require_relative 'test_helper'
require 'json'

module Dn1supBenchmark::Test
  S = Dn1supBenchmark::Score
  SCORE_BASELINE = File.expand_path('../baseline-small-v1.json', __dir__)

  def self.score_run(values)
    results = values.map do |id, (value, unit)|
      { 'id' => id, 'name' => id, 'group' => 'api', 'category' => 'api',
        'test_version' => '1', 'unit' => unit, 'higher_is_better' => unit == 'fps',
        'status' => 'passed', 'parameters' => {}, 'repeat_count' => 1,
        'times_ms' => unit == 'fps' ? [value] : [value],
        'median_ms' => unit == 'fps' ? nil : value, 'min_ms' => value, 'max_ms' => value,
        'p95_ms' => nil, 'ops_per_sec' => nil, 'entities' => nil,
        'entities_created' => nil, 'file_size_bytes' => nil,
        'validation' => { 'passed' => true, 'errors' => [] },
        'error' => nil, 'diagnostics' => [], 'value' => value }
    end
    { 'meta' => { 'profile' => 'small', 'test_suite_version' => '2' },
      'run' => { 'status' => 'completed' }, 'results' => results }
  end

  test 'веса опубликованы и в сумме дают 1' do
    assert((S::WEIGHTS.values.sum - 1.0).abs < 1e-9, "сумма весов #{S::WEIGHTS.values.sum}")
    S::WEIGHTS.keys.each do |cat|
      assert(S::INCLUDED.key?(cat), "для категории #{cat} нет набора тестов")
      refute(S::INCLUDED[cat].empty?, "категория #{cat} пуста")
    end
  end

  test 'прогон на базовых значениях даёт ~1000' do
    base = JSON.parse(File.read(SCORE_BASELINE))['values']
    values = base.transform_values { |v| [v['value'], v['unit']] }
    score = S.compute(score_run(values))
    assert_equal('complete', score['status'])
    assert(score['overall'] > 990 && score['overall'] < 1010,
           "балл на базе должен быть ~1000, получили #{score['overall']}")
  end

  test 'быстрая машина (×2) даёт ~2000' do
    base = JSON.parse(File.read(SCORE_BASELINE))['values']
    values = base.transform_values do |v|
      v['unit'] == 'fps' ? [v['value'] * 2, v['unit']] : [v['value'] / 2, v['unit']]
    end
    score = S.compute(score_run(values))
    assert(score['overall'] > 1900 && score['overall'] < 2100,
           "ожидали ~2000, получили #{score['overall']}")
  end

  test 'пропущенный тест → partial с перечнем' do
    base = JSON.parse(File.read(SCORE_BASELINE))['values']
    values = base.transform_values { |v| [v['value'], v['unit']] }
    values.delete('API-03')
    score = S.compute(score_run(values))
    assert_equal('partial', score['status'])
    assert_equal(['API-03'], score['missing'])
    assert(!score['overall'].nil?, 'частичный балл всё равно считается')
  end

  test 'упавший тест не участвует' do
    base = JSON.parse(File.read(SCORE_BASELINE))['values']
    values = base.transform_values { |v| [v['value'], v['unit']] }
    run = score_run(values)
    run['results'].find { |r| r['id'] == 'DOC-01' }['status'] = 'failed'
    score = S.compute(run)
    assert_equal('partial', score['status'])
    assert(score['missing'].include?('DOC-01'))
  end

  test 'профиль без baseline → unavailable с причиной' do
    run = score_run({})
    run['meta']['profile'] = 'medium'
    score = S.compute(run)
    assert_equal('unavailable', score['status'])
    assert_nil(score['overall'])
    assert(score['reason'].to_s.include?('medium'))
  end

  test 'nil-прогон → nil, кривой прогон → unavailable без падения' do
    assert_nil(S.compute(nil))
    score = S.compute('results' => 42, 'meta' => { 'profile' => 'small' })
    assert_equal('unavailable', score['status'])
  end

  test 'баллы сравнимы только в одном профиле' do
    rep = Dn1supBenchmark::Report
    a = { 'profile' => 'small', 'overall' => 1000.0 }
    assert_nil(rep.score_compatibility(a, { 'profile' => 'small', 'overall' => 1200.0 }))
    assert_equal('профиль различается', rep.score_compatibility(a, { 'profile' => 'medium', 'overall' => 1200.0 }))
    assert_equal('нет балла', rep.score_compatibility(a, { 'profile' => 'small', 'overall' => nil }))
  end
end
