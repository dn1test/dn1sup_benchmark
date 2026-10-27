# frozen_string_literal: true
# dn1sup_benchmark/test/report_test.rb — генерация отчётов (на фикстурах).

require_relative 'test_helper'
require 'json'

module Dn1supBenchmark::Test
  def self.fixture_run(su_version, fps, ms)
    {
      'meta' => {
        'extension_version' => Dn1supBenchmark::VERSION, 'profile' => 'quick',
        'sketchup_version' => su_version, 'version_number' => 24_0_000,
        'ruby_version' => RUBY_VERSION, 'platform' => RUBY_PLATFORM,
        'cpu' => 'Test CPU', 'cores' => 8, 'extensions_loaded' => 1,
        'started_at' => '2026-10-28 10:00:00'
      },
      'results' => [
        { 'group' => 'viewport', 'id' => 'fps_grid_static', 'name' => 'FPS: сетка',
          'unit' => 'fps', 'higher_is_better' => true, 'times_ms' => [fps],
          'entities' => 625, 'error' => nil, 'median' => fps, 'min' => fps,
          'max' => fps, 'value' => fps },
        { 'group' => 'editing', 'id' => 'pushpull_batch', 'name' => 'Push/pull',
          'unit' => 'ms', 'higher_is_better' => false, 'times_ms' => [ms, ms + 10],
          'entities' => 40, 'error' => nil, 'median' => ms + 5, 'min' => ms,
          'max' => ms + 10, 'value' => ms + 5 }
      ],
      'log' => []
    }
  end

  test 'html_single: самодостаточный HTML с группами' do
    html = Dn1supBenchmark::Report.html_single(fixture_run('27.0.999', 60.0, 120.0))
    assert(html.include?('<html'), 'нет <html>')
    assert(html.include?('FPS'), 'нет строк FPS')
    assert(html.include?('Push/pull'), 'нет имени теста')
    refute(html.include?('http://cdn') || html.include?('https://'), 'отчёт не должен тянуть CDN')
  end

  test 'compare: колонки версий и проценты к базе' do
    a = fixture_run('24.0.999', 50.0, 100.0)
    b = fixture_run('27.0.999', 60.0, 90.0)
    html = Dn1supBenchmark::Report.html_compare([a, b])
    assert(html.include?('SU24.0.999') && html.include?('SU27.0.999'), 'нет колонок версий')
    assert(html.include?('+'), 'нет процентов сравнения')
  end

  test 'fmt: единицы' do
    f = Dn1supBenchmark::Report
    assert_equal('60.0 fps', f.fmt(60.0, 'fps'))
    assert_equal('120.5 мс', f.fmt(120.5, 'ms'))
    assert_equal('1.5 с', f.fmt(1500, 'ms'))
    assert_equal('—', f.fmt(nil, 'ms'))
  end
end
