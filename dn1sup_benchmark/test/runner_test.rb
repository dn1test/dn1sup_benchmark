# frozen_string_literal: true
# dn1sup_benchmark/test/runner_test.rb — методика раннера и контракт теста
# (без живого прогона: он проверяется калибровочным запуском набора).

require_relative 'test_helper'

module Dn1supBenchmark::Test
  R = Dn1supBenchmark::Runner

  test 'SUITE: один набор с параметрами пяти категорий' do
    %w[diverse poly wave tools storage].each do |key|
      assert(R::SUITE[key].is_a?(Hash), "нет параметров #{key}")
    end
    assert(R::SUITE['target_mb'].to_f.positive?, 'цель файла')
    assert(R::SUITE['targets']['instances'].positive?, 'цель по инстансам')
    assert_equal('suite', R::SUITE_PROFILE, 'одно имя профиля для отчётов и baseline')
  end

  test 'suite_params: полная независимая копия набора' do
    p = R.suite_params
    assert_equal(R::SUITE['storage']['boxes'], p['storage']['boxes'])
    assert_equal('suite', p['profile'], 'в параметрах есть имя профиля для отчёта')
    assert_equal('hd', p['resolution'], 'разрешение по умолчанию')
    p['storage']['boxes'] = 1
    p['target_mb'] = 9999
    assert_equal(R::SUITE['storage']['boxes'], R.suite_params['storage']['boxes'],
                 'изменение копии не трогает константу набора')
    assert_equal(500, R.suite_params['target_mb'], 'цель файла фиксирована')
  end

  test 'RESOLUTIONS: три разрешения, нормализация неизвестного → hd' do
    assert_equal(%w[fhd hd qhd], R::RESOLUTIONS.keys.sort, 'ровно три разрешения')
    assert_equal('hd', R.normalize_resolution(nil), 'nil → hd')
    assert_equal('hd', R.normalize_resolution('bogus'), 'неизвестное → hd')
    assert_equal('qhd', R.normalize_resolution('qhd'), 'известное проходит')
    R::RESOLUTIONS.each_value do |(w, h)|
      assert(w >= 640 && h >= 360, "разрешение #{w}x#{h} слишком мало")
    end
  end

  test 'лимиты безопасности (уроки инцидентов SU2027)' do
    prof = R::SUITE
    dv = prof['diverse']
    inst = dv['grid'] * dv['grid'] * dv['leaves']
    assert(inst <= 10_000, "компонентная сцена #{inst} инстансов > 10 000")
    assert(prof['poly']['n'] <= 100, "полигональная сетка #{prof['poly']['n']}² > 100²")
    assert(prof['wave']['grid'] <= 80, "полотно волны #{prof['wave']['grid']}² > 80²")
    assert(prof['wave_s'] <= 12.0, "волна #{prof['wave_s']} с — слишком долго")
    assert(prof['target_mb'] <= 2_000, "цель файла #{prof['target_mb']} МБ слишком велика")
    assert(prof['iters'] <= 3, "iters=#{prof['iters']} слишком много")
    assert(prof['fps_s'] <= 3.0, "fps_s=#{prof['fps_s']} слишком долго")
  end

  test 'steps: план v6 (5 сцен, 4 fps, волна, storage_open)' do
    steps = R.steps
    kinds = steps.map { |s| s['kind'] }
    assert_equal('begin', kinds.first)
    assert_equal('finish', kinds.last)
    assert_equal(5, kinds.count('scene'), "ожидали 5 сцен: #{kinds}")
    assert_equal(4, kinds.count('fps'), '4 FPS-шага (компоненты ×2 + полигоны ×2)')
    assert_equal(1, kinds.count('wave'), 'один шаг волны')
    assert_equal(1, kinds.count('storage_open'), 'один шаг открытия файла')
    scenes = steps.select { |s| s['kind'] == 'scene' }.map { |s| s['scene'] }
    assert_equal(%w[diverse poly tools wave storage], scenes, 'порядок сцен')
    refute(kinds.include?('ruby'), 'RUBY-шаг удалён (suite v4)')
    refute(kinds.include?('doc'), 'DOC-шаг удалён (suite v4)')
    modes = steps.select { |s| s['kind'] == 'fps' }.map { |s| s['mode'] }
    refute(modes.include?('pages'), 'page-switch запрещён (инцидент 2026-10-28)')
    assert_equal(500, R::SUITE['target_mb'], 'цель файла набора ~500 МБ')
  end

  test 'предупреждение набора упоминает файл и длительность' do
    assert(R::SUITE_WARNING.include?('МБ'), 'предупреждение о файле обязательно')
    assert(R::SUITE_WARNING.include?('минут'), 'предупреждение о длительности прогона')
  end

  test 'plan_preview: полный план с предупреждением и разрешением' do
    pp = R.plan_preview
    assert(pp['warning'].to_s.include?('МБ'), 'предупреждение должно упоминать файл')
    assert_equal(R.steps.size, pp['steps'].size, 'в превью все шаги')
    assert_equal('suite', pp['profile'], 'превью называет единственный набор')
    assert_equal('hd', pp['params']['resolution'], 'дефолтное разрешение в плане')
    assert_equal('1920x1080', pp['resolutions']['fhd'], 'список доступных разрешений')
    assert_equal('qhd', R.plan_preview('qhd')['params']['resolution'],
                 'выбранное разрешение попадает в план')
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
    rec = R.add_result('tools', 'TOOL-T', 'Тест', 'ms', [0.010, 0.020, 0.030],
                       entities: 5, params: { 'x' => 1 }, ops: 300)
    assert_equal('passed', rec['status'])
    assert_equal('1', rec['test_version'])
    assert_equal('tools', rec['category'])
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
    rec = R.add_result('modeling', 'MODEL-F', 'Тест', 'ms', [],
                       diagnostics: [{ 'class' => 'RuntimeError', 'message' => 'бум', 'backtrace' => [] }])
    assert_equal('failed', rec['status'])
    assert(rec['error'].to_s.include?('RuntimeError'))
    rec2 = R.add_result('modeling', 'MODEL-V', 'Тест', 'ms', [0.001],
                        validation_errors: ['не совпало'])
    assert_equal('passed', rec2['status'])
    refute(rec2['validation']['passed'], 'валидация должна быть не пройдена')
  ensure
    R.instance_variable_set(:@state, nil)
  end

  test 'add_skipped: статус и причина' do
    R.instance_variable_set(:@state, { 'results' => [] })
    rec = R.add_skipped('storage', 'STORAGE-X', 'Тест', 'причина пропуска')
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

  test 'perform неизвестного шага не падает' do
    assert(R.perform({ 'kind' => 'zzz' }).is_a?(String))
  end

  test 'async_step_limit: масштабируется от длительности волны' do
    R.instance_variable_set(:@state, { 'params' => { 'wave_s' => 10.0 } })
    assert_equal(30.0, R.async_step_limit, 'минимум 30 с')
    R.instance_variable_set(:@state, { 'params' => { 'wave_s' => 50.0 } })
    assert_equal(150.0, R.async_step_limit, '3 × wave_s')
    R.instance_variable_set(:@state, nil)
    assert_equal(30.0, R.async_step_limit, 'вне прогона — 30 с')
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

  test 'queue_front: работы встают в голову в порядке перечисления' do
    # Регрессия калибровки storage: проба обязана идти ПОСЛЕ задачи текстур.
    st = { 'jobs' => %i[tail] }
    R.queue_front(st, [:task, :t1], [:sync, :s1])
    assert_equal([[:task, :t1], [:sync, :s1], :tail], st['jobs'],
                 'задача и следующий за ней sync должны сохранять порядок')
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
