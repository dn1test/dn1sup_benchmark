# frozen_string_literal: true
# dn1sup_benchmark/test/schema_test.rb — соответствие отчёта прогона
# schemas/result-schema-v1.json. Полный JSON-Schema-валидатор не тащим
# (без новых зависимостей): проверяем required/const/enum по всем уровням
# для структур, которыми реально пользуется раннер.

require_relative 'test_helper'
require 'json'

module Dn1supBenchmark::Test
  SCHEMA_PATH = File.expand_path('../schemas/result-schema-v1.json', __dir__)

  def self.load_schema
    skip("schema_test: нет #{SCHEMA_PATH} (запуск из установленного плагина)") unless File.exist?(SCHEMA_PATH)
    JSON.parse(File.read(SCHEMA_PATH))
  end

  # Мини-валидатор: required, const, enum, type, $ref (внутри root-схемы).
  def self.validate(node, schema, path, errors, root = nil)
    return if schema.nil?

    root ||= schema
    if (ref = schema['$ref'])
      target = root
      ref.split('/').reject { |p| p == '#' || p.empty? }.each do |part|
        target = target.is_a?(Hash) ? target[part] : nil
      end
      return validate(node, target, path, errors, root)
    end

    if (req = schema['required'])
      req.each do |key|
        errors << "#{path}: нет обязательного поля #{key}" unless node.is_a?(Hash) && node.key?(key)
      end
    end
    if schema['const']
      errors << "#{path}: const — ожидали #{schema['const'].inspect}, получили #{node.inspect}" if node != schema['const']
    end
    if (enum = schema['enum'])
      errors << "#{path}: #{node.inspect} вне enum" unless enum.include?(node)
    end
    if (types = schema['type'])
      types = Array(types)
      ok = types.any? do |t|
        case t
        when 'object' then node.is_a?(Hash)
        when 'array' then node.is_a?(Array)
        when 'string' then node.is_a?(String)
        when 'integer' then node.is_a?(Integer)
        when 'number' then node.is_a?(Numeric)
        when 'boolean' then node == true || node == false
        when 'null' then node.nil?
        else true
        end
      end
      errors << "#{path}: тип #{node.class} вне #{types.join('|')}" unless ok
    end
    props = schema['properties']
    if props.is_a?(Hash) && node.is_a?(Hash)
      props.each do |key, sub|
        validate(node[key], sub, "#{path}.#{key}", errors, root) if node.key?(key)
      end
    end
    if (items = schema['items']) && node.is_a?(Array)
      node.each_with_index { |el, i| validate(el, items, "#{path}[#{i}]", errors, root) }
    end
  end

  # Имя нарочито иное, чем fixture_run в report_test: оба файла открывают
  # один модуль Test, одноимённые singleton-методы перезаписали бы друг друга.
  def self.schema_fixture_run
    {
      'meta' => {
        'schema_version' => 1,
        'benchmark_version' => Dn1supBenchmark::VERSION,
        'test_suite_version' => '5',
        'extension_version' => Dn1supBenchmark::VERSION,
        'profile' => 'suite',
        'params' => { 'iters' => 3 },
        'sketchup_version' => '24.0.594', 'version_number' => 2_400_000_594,
        'ruby_version' => RUBY_VERSION, 'ruby_description' => RUBY_DESCRIPTION,
        'platform' => RUBY_PLATFORM, 'os' => 'Windows_NT',
        'cpu' => 'Test CPU', 'cores' => 8, 'extensions_loaded' => 1,
        'started_at' => '2026-10-28 10:00:00',
        'environment' => { 'ui_scale_factor' => 1.0,
                           'viewport' => { 'width' => 1000, 'height' => 800 },
                           'graphics_engine' => nil, 'graphics_engine_note' => 'нет' },
        'sources' => { 'fps' => 'внутренний замер' }
      },
      'run' => { 'profile' => 'suite', 'status' => 'completed', 'started_at' => 'x' },
      'results' => [
        { 'id' => 'model_build', 'name' => 'Сборка сложной модели', 'group' => 'modeling', 'category' => 'modeling',
          'test_version' => '1', 'unit' => 'ms', 'higher_is_better' => false,
          'status' => 'passed', 'parameters' => {}, 'repeat_count' => 3,
          'times_ms' => [10.0, 11.0, 12.0], 'median_ms' => 11.0, 'min_ms' => 10.0,
          'max_ms' => 12.0, 'p95_ms' => nil, 'ops_per_sec' => 1.0, 'entities' => nil,
          'entities_created' => nil, 'file_size_bytes' => nil,
          'validation' => { 'passed' => true, 'errors' => [] },
          'error' => nil, 'diagnostics' => [], 'value' => 11.0 },
        { 'id' => 'fps_components_orbit', 'name' => 'FPS', 'group' => 'viewport', 'category' => 'viewport',
          'test_version' => '1', 'unit' => 'fps', 'higher_is_better' => true,
          'status' => 'skipped', 'parameters' => {}, 'repeat_count' => 0,
          'times_ms' => [], 'median_ms' => nil, 'min_ms' => nil, 'max_ms' => nil,
          'p95_ms' => nil, 'ops_per_sec' => nil, 'entities' => nil,
          'entities_created' => nil, 'file_size_bytes' => nil,
          'validation' => { 'passed' => false, 'errors' => ['нет кадров'] },
          'error' => 'нет кадров', 'diagnostics' => [], 'value' => nil }
      ],
      'log' => []
    }
  end

  test 'валидный прогон соответствует схеме v1' do
    schema = load_schema
    errors = []
    validate(schema_fixture_run, schema, '$', errors)
    assert(errors.empty?, errors.join('; '))
  end

  test 'битый прогон схема ловит' do
    schema = load_schema
    bad = schema_fixture_run
    bad['meta'].delete('sketchup_version')
    bad['results'][0]['status'] = 'broken'
    errors = []
    validate(bad, schema, '$', errors)
    assert(errors.any? { |e| e.include?('sketchup_version') }, "нет ошибки по meta: #{errors}")
    assert(errors.any? { |e| e.include?('enum') && e.include?('results') }, "нет ошибки по статусу: #{errors}")
  end

  test 'реальный последний отчёт соответствует схеме (если есть)' do
    skip('вне SketchUp: отчётов ещё нет') unless defined?(Sketchup)
    runs = Dn1supBenchmark::Report.list_runs(5)
    runs = runs.select { |r| r['suite'] == Dn1supBenchmark::Runner::SUITE_VERSION }
    skip('прогонов текущего набора ещё не было') if runs.empty?
    schema = load_schema
    data = JSON.parse(File.read(runs.first['path']))
    errors = []
    validate(data, schema, '$', errors)
    assert(errors.empty?, errors.first(5).join('; '))
  end
end
