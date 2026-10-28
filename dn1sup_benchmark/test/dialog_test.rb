# frozen_string_literal: true
# dn1sup_benchmark/test/dialog_test.rb — Ruby-сторона панели (данные и
# настройки). Само окно НЕ открывается ни тестами, ни консолью: show() —
# только явное действие пользователя из меню (правило безопасности).

require_relative 'test_helper'
require_relative '../dialog' unless defined?(Dn1supBenchmark::Dialog)

module Dn1supBenchmark::Test
  D = Dn1supBenchmark::Dialog

  test 'dialog: plan_data отдаёт шаги и категории' do
    data = D.send(:plan_data, 'small', nil)
    assert(data['steps'].size >= 14, 'полный план шагов')
    assert(data['categories'].is_a?(Array) && !data['categories'].empty?, 'категории для фильтра')
    assert(data['params'].is_a?(Hash), 'параметры профиля')
  end

  test 'dialog: plan_data предупреждение для large' do
    assert(!D.send(:plan_data, 'large', nil)['warning'].nil?, 'предупреждение для large обязательно')
  end

  test 'dialog: run_results_data группирует результаты' do
    run = {
      'meta' => { 'sketchup_version' => '27.0', 'profile' => 'small', 'started_at' => 'x',
                  'test_suite_version' => '2', 'ruby_version' => RUBY_VERSION, 'cpu' => 'T' },
      'run' => { 'status' => 'completed' },
      'results' => [
        { 'id' => 'RUBY-01', 'name' => 'Ruby', 'group' => 'ruby', 'status' => 'passed',
          'unit' => 'ms', 'value' => 1.0, 'min_ms' => 1.0, 'max_ms' => 1.0, 'p95_ms' => nil,
          'repeat_count' => 3, 'ops_per_sec' => 9.0, 'entities' => nil, 'error' => nil,
          'higher_is_better' => false }
      ]
    }
    out = D.send(:run_results_data, run)
    assert_equal(1, out['groups'].size)
    assert_equal('RUBY-01', out['groups'].first['tests'].first['id'])
    assert_equal('completed', out['run']['status'])
  end

  test 'dialog: load_settings валиден и мержит дефолты' do
    s = D.send(:load_settings)
    assert(s.is_a?(Hash))
    assert(s.key?('profile'), 'есть профиль')
    assert(s.key?('doc_enabled'), 'есть флаг DOC')
  end
end
