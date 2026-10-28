# frozen_string_literal: true
# dn1sup_benchmark/test/report_test.rb — генерация отчётов (на фикстурах)
# и правила совместимости сравнения (ТЗ §12).

require_relative 'test_helper'
require 'json'

module Dn1supBenchmark::Test
  def self.fixture_result(id, group, unit, value, params: { 'batch' => 10 }, version: '1')
    {
      'id' => id, 'name' => "Тест #{id}", 'group' => group, 'category' => group,
      'test_version' => version, 'unit' => unit, 'higher_is_better' => unit == 'fps',
      'status' => 'passed', 'parameters' => params,
      'repeat_count' => 3, 'times_ms' => unit == 'fps' ? [value] : [value, value + 10],
      'median_ms' => unit == 'fps' ? nil : value + 5,
      'min_ms' => value, 'max_ms' => value + 10, 'p95_ms' => nil,
      'ops_per_sec' => nil, 'entities' => 40, 'entities_created' => nil,
      'file_size_bytes' => nil,
      'validation' => { 'passed' => true, 'errors' => [] },
      'error' => nil, 'diagnostics' => [],
      'value' => value
    }
  end

  def self.fixture_run(su_version, fps, ms, profile: 'small')
    {
      'meta' => {
        'schema_version' => 1,
        'benchmark_version' => Dn1supBenchmark::VERSION,
        'test_suite_version' => '2',
        'extension_version' => Dn1supBenchmark::VERSION,
        'profile' => profile,
        'sketchup_version' => su_version, 'version_number' => 24_0_000,
        'ruby_version' => RUBY_VERSION, 'ruby_description' => RUBY_DESCRIPTION,
        'platform' => RUBY_PLATFORM, 'os' => 'Windows_NT',
        'cpu' => 'Test CPU', 'cores' => 8, 'extensions_loaded' => 1,
        'started_at' => '2026-10-28 10:00:00',
        'environment' => { 'ui_scale_factor' => 1.0,
                           'viewport' => { 'width' => 1000, 'height' => 800 },
                           'graphics_engine' => nil },
        'sources' => { 'fps' => 'тест' }
      },
      'run' => { 'profile' => profile, 'status' => 'completed', 'started_at' => '2026-10-28 10:00:00' },
      'results' => [
        fixture_result('fps_grid_static', 'graphics', 'fps', fps),
        fixture_result('pushpull_batch', 'api', 'ms', ms)
      ],
      'log' => []
    }
  end

  test 'html_single: самодостаточный HTML с категориями и статусами' do
    data = fixture_run('27.0.999', 60.0, 120.0)
    data['results'] << fixture_result('DOC-X', 'documents', 'ms', 5.0).merge(
      'status' => 'skipped', 'value' => nil, 'error' => 'отключено',
      'validation' => { 'passed' => false, 'errors' => ['отключено'] }
    )
    html = Dn1supBenchmark::Report.html_single(data)
    assert(html.include?('<html'), 'нет <html>')
    assert(html.include?('FPS'), 'нет строк FPS')
    assert(html.include?('Чистый Ruby') || html.include?('SketchUp API'), 'нет категорий')
    assert(html.include?('пропущено'), 'нет статуса skipped')
    refute(html.include?('http://cdn') || html.include?('https://'), 'отчёт не должен тянуть CDN')
  end

  test 'compare: совместимые пары получают проценты' do
    a = fixture_run('24.0.999', 50.0, 100.0)
    b = fixture_run('27.0.999', 60.0, 90.0)
    html = Dn1supBenchmark::Report.html_compare([a, b])
    assert(html.include?('SU24.0.999') && html.include?('SU27.0.999'), 'нет колонок версий')
    assert(html.include?('+'), 'нет процентов сравнения')
    refute(html.include?('Несовместимые пары'), 'совместимые прогоны не должны давать предупреждений')
  end

  test 'compare: разные параметры нагрузки → предупреждение, без процентов' do
    a = fixture_run('24.0.999', 50.0, 100.0)
    b = fixture_run('27.0.999', 60.0, 90.0)
    b['results'].each { |r| r['parameters'] = { 'batch' => 999 } }
    html = Dn1supBenchmark::Report.html_compare([a, b])
    assert(html.include?('параметры нагрузки различаются'), 'нет предупреждения о параметрах')
  end

  test 'compare: разная версия теста → предупреждение' do
    a = fixture_run('24.0.999', 50.0, 100.0)
    b = fixture_run('27.0.999', 60.0, 90.0)
    b['results'].each { |r| r['test_version'] = '2' }
    html = Dn1supBenchmark::Report.html_compare([a, b])
    assert(html.include?('версия теста'), 'нет предупреждения о версии теста')
  end

  test 'incompatibility_reason: все ветки' do
    rep = Dn1supBenchmark::Report
    x = fixture_result('T', 'api', 'ms', 1.0, params: { 'a' => 1, 'nested' => { 'b' => 2 } })
    assert_nil(rep.incompatibility_reason(x, fixture_result('T', 'api', 'ms', 2.0,
                                                            params: { 'nested' => { 'b' => 2 }, 'a' => 1 })))
    assert(rep.incompatibility_reason(x, fixture_result('T', 'api', 'ms', 2.0, version: '2')))
    assert(rep.incompatibility_reason(x, fixture_result('T', 'api', 'fps', 2.0)))
    assert(rep.incompatibility_reason(x, fixture_result('T', 'api', 'ms', 2.0, params: { 'a' => 2 })))
    old = fixture_result('T', 'api', 'ms', 1.0).merge('test_version' => nil)
    assert(rep.incompatibility_reason(x, old).to_s.include?('версии теста'))
  end

  test 'fmt: единицы' do
    f = Dn1supBenchmark::Report
    assert_equal('60.0 fps', f.fmt(60.0, 'fps'))
    assert_equal('120.5 мс', f.fmt(120.5, 'ms'))
    assert_equal('1.5 с', f.fmt(1500, 'ms'))
    assert_equal('—', f.fmt(nil, 'ms'))
  end

  test 'list_runs: читает сохранённые прогоны (если есть)' do
    runs = Dn1supBenchmark::Report.list_runs(5)
    assert(runs.is_a?(Array))
    runs.each do |r|
      assert(r['path'] && r['file'], 'нет пути прогона')
      assert(r['sketchup'], 'нет версии SketchUp')
    end
  end
end
