# frozen_string_literal: true
# dn1sup_benchmark/test/score_test.rb — необязательный общий балл
# (Geekbench-стиль): формула, веса, статусы, база.

require_relative 'test_helper'
require 'json'

module Dn1supBenchmark::Test
  S = Dn1supBenchmark::Score
  BASELINE_V6 = File.expand_path('../baseline-suite-v6.json', __dir__)

  def self.score_run(values)
    results = values.map do |id, (value, unit)|
      { 'id' => id, 'name' => id, 'group' => 'tools', 'category' => 'tools',
        'test_version' => '1', 'unit' => unit, 'higher_is_better' => unit == 'fps',
        'status' => 'passed', 'parameters' => {}, 'repeat_count' => 1,
        'times_ms' => [value], 'median_ms' => unit == 'fps' ? nil : value,
        'min_ms' => value, 'max_ms' => value,
        'p95_ms' => nil, 'ops_per_sec' => nil, 'entities' => nil,
        'entities_created' => nil, 'file_size_bytes' => nil,
        'validation' => { 'passed' => true, 'errors' => [] },
        'error' => nil, 'diagnostics' => [], 'value' => value }
    end
    { 'meta' => { 'profile' => 'suite', 'test_suite_version' => '6' },
      'run' => { 'status' => 'completed' }, 'results' => results }
  end

  # Подмена базы: формулу проверяем на синтетической базе (все включённые
  # тесты), живая baseline-suite-v5.json проверяется отдельным тестом.
  def self.with_fake_baseline
    fake = { 'profile' => 'suite',
             'values' => S::INCLUDED.values.flatten.each_with_object({}) do |id, h|
               h[id] = id.start_with?('fps_') ? { 'value' => 50.0, 'unit' => 'fps' } : { 'value' => 100.0, 'unit' => 'ms' }
             end,
             'reference' => { 'source_run' => 'fake', 'resolution' => 'hd' } }
    S.singleton_class.send(:alias_method, :real_load_baseline, :load_baseline)
    S.singleton_class.send(:define_method, :load_baseline) { |profile| profile == 'suite' ? fake : nil }
    yield fake
  ensure
    S.singleton_class.send(:alias_method, :load_baseline, :real_load_baseline)
    S.singleton_class.send(:remove_method, :real_load_baseline)
  end

  def self.baseline_values(baseline)
    baseline['values'].transform_values { |v| [v['value'], v['unit']] }
  end

  test 'веса опубликованы и в сумме дают 1' do
    assert((S::WEIGHTS.values.sum - 1.0).abs < 1e-9, "сумма весов #{S::WEIGHTS.values.sum}")
    assert_equal(S::WEIGHTS.keys.sort, S::INCLUDED.keys.sort, 'наборы тестов есть для всех категорий')
    S::INCLUDED.each do |cat, ids|
      refute(ids.empty?, "категория #{cat} пуста")
    end
  end

  test 'прогон на базовых значениях даёт ~1000' do
    with_fake_baseline do |baseline|
      score = S.compute(score_run(baseline_values(baseline)))
      assert_equal('complete', score['status'])
      assert(score['overall'] > 990 && score['overall'] < 1010,
             "балл на базе должен быть ~1000, получили #{score['overall']}")
      assert_equal(5, score['categories'].size, 'пять категорий suite v4')
    end
  end

  test 'быстрая машина (×2) даёт ~2000' do
    with_fake_baseline do |baseline|
      values = baseline_values(baseline).transform_values do |value, unit|
        unit == 'fps' ? [value * 2, unit] : [value / 2, unit]
      end
      score = S.compute(score_run(values))
      assert(score['overall'] > 1900 && score['overall'] < 2100,
             "ожидали ~2000, получили #{score['overall']}")
    end
  end

  test 'пропущенный тест → partial с перечнем' do
    with_fake_baseline do |baseline|
      values = baseline_values(baseline)
      values.delete('tool_draw')
      score = S.compute(score_run(values))
      assert_equal('partial', score['status'])
      assert_equal(['tool_draw'], score['missing'])
      assert(!score['overall'].nil?, 'частичный балл всё равно считается')
    end
  end

  test 'упавший тест не участвует' do
    with_fake_baseline do |baseline|
      run = score_run(baseline_values(baseline))
      run['results'].find { |r| r['id'] == 'storage_save' }['status'] = 'failed'
      score = S.compute(run)
      assert_equal('partial', score['status'])
      assert(score['missing'].include?('storage_save'))
    end
  end

  test 'другое разрешение вьюпорта → unavailable с причиной' do
    with_fake_baseline do |baseline|
      run = score_run(baseline_values(baseline))
      run['meta']['params'] = { 'resolution' => 'qhd' }
      score = S.compute(run)
      assert_equal('unavailable', score['status'])
      assert_nil(score['overall'])
      assert(score['reason'].to_s.include?('qhd'), 'причина называет разрешение прогона')
    end
  end

  test 'разрешение базы совпало → балл считается' do
    with_fake_baseline do |baseline|
      run = score_run(baseline_values(baseline))
      run['meta']['params'] = { 'resolution' => 'hd' }
      score = S.compute(run)
      assert_equal('complete', score['status'])
    end
  end

  test 'набор без baseline → unavailable с причиной' do
    with_fake_baseline do
      run = score_run({})
      run['meta']['profile'] = 'unknown'
      score = S.compute(run)
      assert_equal('unavailable', score['status'])
      assert_nil(score['overall'])
      assert(score['reason'].to_s.include?('unknown'))
    end
  end

  test 'nil-прогон → nil, кривой прогон → unavailable без падения' do
    with_fake_baseline do
      assert_nil(S.compute(nil))
      score = S.compute('results' => 42, 'meta' => { 'profile' => 'suite' })
      assert_equal('unavailable', score['status'])
    end
  end

  test 'реальная база (если заморожена): файл v6 валиден' do
    skip("нет #{File.basename(BASELINE_V6)} — замораживается живым прогоном") unless File.exist?(BASELINE_V6)
    base = JSON.parse(File.read(BASELINE_V6))
    ids = base['values'].keys
    S::INCLUDED.values.flatten.each do |id|
      assert(ids.include?(id), "в базе нет #{id}")
    end
    # Балл прогона «в точности как база» обязан получиться ~1000.
    score = S.compute(score_run(base['values'].transform_values { |v| [v['value'], v['unit']] }))
    assert(score['overall'].to_f > 990 && score['overall'].to_f < 1010,
           "балл на реальной базе должен быть ~1000, получили #{score['overall']}")
  end

  test 'баллы сравнимы только в одном наборе' do
    rep = Dn1supBenchmark::Report
    a = { 'profile' => 'suite', 'overall' => 1000.0 }
    assert_nil(rep.score_compatibility(a, { 'profile' => 'suite', 'overall' => 1200.0 }))
    assert_equal('профиль различается', rep.score_compatibility(a, { 'profile' => 'small', 'overall' => 1200.0 }))
    assert_equal('нет балла', rep.score_compatibility(a, { 'profile' => 'suite', 'overall' => nil }))
  end
end
