# frozen_string_literal: true
# dn1sup_benchmark/test/dialog_test.rb — Ruby-сторона панели (данные и
# настройки). Само окно НЕ открывается ни тестами, ни консолью: show() —
# только явное действие пользователя из меню (правило безопасности).

require_relative 'test_helper'
require_relative '../dialog' unless defined?(Dn1supBenchmark::Dialog)

module Dn1supBenchmark::Test
  D = Dn1supBenchmark::Dialog

  test 'dialog: plan_data отдаёт шаги и категории' do
    data = D.send(:plan_data)
    assert(data['steps'].size >= 12, 'полный план шагов (suite v5: 14 шагов)')
    assert(data['categories'].is_a?(Array) && !data['categories'].empty?, 'категории для фильтра')
    assert(data['params'].is_a?(Hash), 'параметры набора')
    assert_equal('suite', data['profile'], 'один набор без выбора')
  end

  test 'dialog: plan_data содержит предупреждение о файле' do
    assert(D.send(:plan_data)['warning'].to_s.include?('МБ'), 'предупреждение о файле обязательно')
  end

  test 'dialog: run_results_data группирует результаты' do
    run = {
      'meta' => { 'sketchup_version' => '27.0', 'profile' => 'suite', 'started_at' => 'x',
                  'test_suite_version' => '5', 'ruby_version' => RUBY_VERSION, 'cpu' => 'T' },
      'run' => { 'status' => 'completed' },
      'results' => [
        { 'id' => 'tool_draw', 'name' => 'Черчение', 'group' => 'tools', 'status' => 'passed',
          'unit' => 'ms', 'value' => 1.0, 'min_ms' => 1.0, 'max_ms' => 1.0, 'p95_ms' => nil,
          'repeat_count' => 3, 'ops_per_sec' => 9.0, 'entities' => nil, 'error' => nil,
          'higher_is_better' => false }
      ]
    }
    out = D.send(:run_results_data, run)
    assert_equal(1, out['groups'].size)
    assert_equal('tool_draw', out['groups'].first['tests'].first['id'])
    assert_equal('completed', out['run']['status'])
  end
end
