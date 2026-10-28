# frozen_string_literal: true
# dn1sup_benchmark/test/runner_test.rb — методика раннера и контракт теста
# (без живого прогона: он проверяется калибровочным запуском small).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  R = Dn1supBenchmark::Runner

  test 'PROFILES: small/medium/large с целями ТЗ, quick/full удалены' do
    %w[small medium large].each do |p|
      prof = R::PROFILES[p]
      assert(prof, "нет профиля #{p}")
      assert(prof['targets']['edges'].positive?, "#{p}: цель по рёбрам")
      assert(prof['targets']['instances'].positive?, "#{p}: цель по инстансам")
    end
    refute(R::PROFILES.key?('quick'), 'quick больше не существует')
    refute(R::PROFILES.key?('full'), 'full больше не существует')
  end

  test 'profile_params: переопределяются только разрешённые ключи' do
    base = R::PROFILES['small']['api01_loops']
    p = R.profile_params('small', 'iters' => 7, 'api01_loops' => 1, 'zzz' => 2)
    assert_equal(7, p['iters'], 'iters переопределяется')
    assert_equal(base, p['api01_loops'], 'служебные ключи не переопределяются')
    assert_raises(ArgumentError) { R.profile_params('mega') }
    assert_raises(ArgumentError) { R.profile_params('custom', nil) }
    custom = R.profile_params('custom', R::PROFILES['small'])
    assert_equal('custom', custom['profile'], 'custom принимает полный набор параметров')
  end

  test 'steps: план v2 (ruby, 5 сцен, 6 fps, doc)' do
    steps = R.steps('small')
    kinds = steps.map { |s| s['kind'] }
    assert_equal('begin', kinds.first)
    assert_equal('finish', kinds.last)
    assert_equal(5, kinds.count('scene'), "ожидали 5 сцен: #{kinds}")
    assert_equal(6, kinds.count('fps'), 'компоненты + 4 режима сетки + текстуры')
    assert(kinds.include?('ruby'), 'нет RUBY-шага')
    assert(kinds.include?('doc'), 'нет DOC-шага')
    scenes = steps.select { |s| s['kind'] == 'scene' }.map { |s| s['scene'] }
    assert_equal(%w[basics nested components grid textured], scenes, 'порядок сцен')
    modes = steps.select { |s| s['kind'] == 'fps' }.map { |s| s['mode'] }
    %w[static orbit pan zoom].each do |m|
      assert(modes.include?(m), "нет FPS-режима #{m}")
    end
    refute(modes.include?('pages'), 'page-switch запрещён (инцидент 2026-10-28)')
  end

  test 'steps: неизвестный профиль даёт ошибку' do
    assert_raises(ArgumentError) { R.steps('mega') }
  end

  test 'plan_preview: предупреждение для large' do
    pp = R.plan_preview('large')
    assert(pp['warning'].to_s.include?('500'), 'предупреждение должно упоминать объём')
    assert_equal(R.steps('large').size, pp['steps'].size, 'в превью все шаги')
    assert_nil(R.plan_preview('small')['warning'])
  end

  test 'median: нечётное, чётное, пустое' do
    assert_equal(2, R.median([3, 1, 2]))
    assert_equal(2.5, R.median([1, 2, 3, 4]))
    assert_nil(R.median([]))
  end

  test 'p95: nil при n<10, ближайший ранг при n>=10' do
    assert_nil(R.p95([3, 1, 2]))
    vals = (1..20).to_a
    assert_equal(19, R.p95(vals), 'ceil(0.95*20)=19 → 19-й элемент сортировки')
  end

  test 'ops_per_sec: объём на медиану' do
    assert_equal(15_000.0, R.ops_per_sec(300, 20.0))
    assert_nil(R.ops_per_sec(nil, 5.0))
    assert_nil(R.ops_per_sec(10, 0.0))
    assert_nil(R.ops_per_sec(10, nil))
  end

  test 'add_result: контракт записи (схема v1)' do
    R.instance_variable_set(:@state, { 'results' => [] })
    rec = R.add_result('api', 'API-T', 'Тест', 'ms', [0.010, 0.020, 0.030],
                       entities: 5, params: { 'x' => 1 }, ops: 300)
    assert_equal('passed', rec['status'])
    assert_equal('1', rec['test_version'])
    assert_equal('api', rec['category'])
    assert_equal(3, rec['repeat_count'])
    assert_equal([10.0, 20.0, 30.0], rec['times_ms'])
    assert_equal(20.0, rec['median_ms'])
    assert_equal(20.0, rec['value'])
    assert_nil(rec['p95_ms'], 'p95 при n<10 отсутствует')
    assert_equal(15_000.0, rec['ops_per_sec'])
    assert(rec['validation']['passed'])
    assert(rec.key?('diagnostics'), 'нет diagnostics')
    assert(rec.key?('file_size_bytes'), 'нет file_size_bytes')
    assert(rec.key?('entities_created'), 'нет entities_created')
  ensure
    R.instance_variable_set(:@state, nil)
  end

  test 'add_result: пустые повторы → failed, ошибки валидации видны' do
    R.instance_variable_set(:@state, { 'results' => [] })
    rec = R.add_result('api', 'API-F', 'Тест', 'ms', [],
                       diagnostics: [{ 'class' => 'RuntimeError', 'message' => 'бум', 'backtrace' => [] }])
    assert_equal('failed', rec['status'])
    assert(rec['error'].to_s.include?('RuntimeError'))
    rec2 = R.add_result('api', 'API-V', 'Тест', 'ms', [0.001],
                        validation_errors: ['не совпало'])
    assert_equal('passed', rec2['status'])
    refute(rec2['validation']['passed'], 'валидация должна быть не пройдена')
  ensure
    R.instance_variable_set(:@state, nil)
  end

  test 'add_skipped: статус и причина' do
    R.instance_variable_set(:@state, { 'results' => [] })
    rec = R.add_skipped('documents', 'DOC-X', 'Тест', 'причина пропуска')
    assert_equal('skipped', rec['status'])
    refute(rec['validation']['passed'])
    assert_equal('причина пропуска', rec['error'])
  ensure
    R.instance_variable_set(:@state, nil)
  end

  test 'отмена: флаг ставится и снимается' do
    R.cancel!
    assert(R.cancelled?)
    R.instance_variable_set(:@cancel_requested, false)
    refute(R.cancelled?)
  end

  test 'RubyWorkload: детерминизм и заявленный объём' do
    w = Dn1supBenchmark::RubyWorkload
    assert_equal(w.run, w.run, 'нагрузка должна быть детерминированной')
    assert(w::TOTAL_OPS >= 300_000, 'объём операций должен быть заметным')
    assert_equal(w::TOTAL_OPS, w.spec['total_ops'], 'спецификация согласована')
  end

  test 'perform неизвестного шага не падает' do
    assert(R.perform({ 'kind' => 'zzz' }).is_a?(String))
  end

  test 'кусковой движок: порции, фазы, суммы и on_finish' do
    task = R.make_task(
      [
        { 'timed' => true, 'total' => 10, 'batch' => 3,
          'work' => ->(from, to, ctx) { ((ctx['a'] ||= []) << [from, to]) } },
        { 'timed' => false, 'total' => 4, 'batch' => 2,
          'work' => ->(from, to, ctx) { ((ctx['b'] ||= []) << [from, to]) } }
      ],
      ->(times, phs, ctx) {
        ctx['out'] = [times.size, phs[0]['sums'].to_f.positive?, phs[1]['sums'].nil?, ctx['a'].size]
      }
    )
    assert_equal :in_progress, R.task_tick(task), 'первый тик — работа не закончена'
    assert_equal([0, 3], task['ctx']['a'].first, 'первая порция [0,3)')
    R.task_drain(task)
    pairs = task['ctx']['a']
    assert_equal(0, pairs.first[0], 'начало с нуля')
    assert_equal(10, pairs.last[1], 'покрытие до 10')
    assert(pairs.each_cons(2).all? { |x, y| x[1] == y[0] }, 'порции стыкуются без пропусков')
    assert_equal([[0, 2], [2, 4]], task['ctx']['b'], 'нетаймированная фаза целиком')
    out = task['ctx']['out']
    assert(out[0] >= 1, 'таймированные куски посчитаны')
    assert(out[1], 'суммы таймированной фазы накоплены')
    assert(out[2], 'у нетаймированной фазы сумм нет')
    assert_equal(pairs.size, out[3], 'все порции дошли до on_finish')
  end

  test 'кусковой движок: отмена прерывает тик' do
    task = R.make_task(
      [{ 'timed' => false, 'total' => 100, 'batch' => 1,
         'work' => ->(_f, _t, _c) { nil } }],
      ->(_t, _p, _c) { nil }
    )
    R.cancel!
    assert_raises(Dn1supBenchmark::Runner::Cancelled) { R.task_tick(task) }
    R.instance_variable_set(:@cancel_requested, false)
  end

  test 'кусковой движок: progress отдаёт done/total' do
    task = R.make_task(
      [{ 'timed' => false, 'total' => 10, 'batch' => 4,
         'work' => ->(_f, _t, _c) { nil } }],
      ->(_t, _p, _c) { nil }
    )
    R.instance_variable_set(:@scene_state, { 'task' => task })
    R.task_tick(task)
    pr = R.task_progress
    assert_equal(4, pr['done'])
    assert_equal(10, pr['total'])
    assert_equal(1, pr['phase'])
  ensure
    R.instance_variable_set(:@scene_state, nil)
  end

  test 'кусковой движок вне прогона: «хвост» @run_model не мешает' do
    # Регрессия 0.3.2: после аварийного стопа @run_model оставался и guard
    # модели ломал любые тики вне прогона (в том числе юнит-тесты).
    R.instance_variable_set(:@run_model, :stale_object)
    task = R.make_task(
      [{ 'timed' => false, 'total' => 3, 'batch' => 3,
         'work' => ->(_f, _t, ctx) { ctx['done'] = true } }],
      ->(_t, _p, ctx) { ctx['finished'] = true }
    )
    assert_equal(:done, R.task_drain(task))
    assert(task['ctx']['done'] && task['ctx']['finished'], 'работа и on_finish выполнены')
  ensure
    R.instance_variable_set(:@run_model, nil)
  end

  test 'abort_run! сбрасывает состояние прогона' do
    R.instance_variable_set(:@state, { 'results' => [] })
    R.instance_variable_set(:@run_model, :stale)
    R.instance_variable_set(:@baseline_entities, 5)
    R.abort_run!
    assert_nil(R.run_data)
    assert_nil(R.instance_variable_get(:@run_model))
    assert_nil(R.instance_variable_get(:@baseline_entities))
    refute(R.cancelled?)
  end
end
