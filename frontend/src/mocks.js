/* Mock-мост для npm run dev в обычном браузере (вне SketchUp).
 * Эмулирует 11 колбэков sketchup.* и поток событий Sequencer, отдаёт
 * fixture-данные той же формы, что присылает dialog.rb. */

import { receive } from './bridge'

function later(fn, ms = 120) { setTimeout(fn, ms) }

const mockOverview = {
  environment: {
    sketchup_version: '27.0.123',
    version_number: '27.0.123 2700123456789',
    ruby_version: 'x64-mingw-ucrt 3.4.5',
    os: 'Windows 11',
    platform: 'x64-mingw-ucrt',
    cpu: 'AMD Ryzen 9 7950X',
    cores: '32',
    benchmark_version: '0.6.0',
    test_suite_version: '4',
    schema_version: '1',
    environment: {
      ui_scale_factor: 1.0,
      viewport: { width: 1280, height: 712 }
    }
  },
  last_run: {
    file: '2026-10-29 12:00',
    profile: 'small',
    sketchup: '27.0.123',
    run: { status: 'passed' },
    tests: 12,
    not_passed: 1,
    score: { overall: 1023.4, status: 'passed' },
    results: [
      { id: 'diverse.asm_instantiation', name: 'Инстанцирование сборок', status: 'passed', unit: 'ms', value: 812 },
      { id: 'diverse.edit_open_close', name: 'Открытие/закрытие сборки', status: 'passed', unit: 'ms', value: 143 },
      { id: 'poly.cyl_draw', name: 'Отрисовка цилиндров', status: 'passed', unit: 'ms', value: 214 },
      { id: 'poly.view_rotate', name: 'Вращение вьюпорта', status: 'passed', unit: 'fps', value: 58.2 },
      { id: 'wave.pushpull', name: 'Волна: Push/Pull', status: 'failed', unit: 'ms', value: 1893 },
      { id: 'tools.draw', name: 'Инструмент Линия', status: 'passed', unit: 'ops', value: 420 },
      { id: 'storage.save_500mb', name: 'Сохранение ~500 МБ', status: 'passed', unit: 'ms', value: 12400 },
      { id: 'storage.open_500mb', name: 'Открытие ~500 МБ', status: 'passed', unit: 'ms', value: 18900 },
      { id: 'png.gen_2k', name: 'Экспорт PNG 2K', status: 'passed', unit: 'ms', value: 1102 },
      { id: 'scenes.switch', name: 'Переключение сцен', status: 'cancelled', unit: 'ms', value: 92 }
    ]
  },
  reports_dir: 'C:\\Users\\dn1desn\\Documents\\SketchUp Benchmarks',
  running: false
}

const mockPlanBase = {
  profile: 'small',
  warning: null,
  params: {
    targets: { instances: 1024, file_mb: 500 },
    diverse: { grid: 16, leaves: 4 },
    poly: { n: 40, segments: 36 },
    wave: { grid: 36 },
    wave_s: 8.0,
    target_mb: 500,
    iters: 3,
    fps_s: 2.0
  },
  steps: [
    { label: 'Сборка: сетка сборок', kind: 'build', category: 'modeling' },
    { label: 'Замер: инстанцирование', kind: 'measure', category: 'modeling' },
    { label: 'Отрисовка цилиндров', kind: 'build', category: 'viewport' },
    { label: 'Замер: вращение', kind: 'measure', category: 'viewport' },
    { label: 'Волна: полотно', kind: 'build', category: 'tools' },
    { label: 'Инструменты: линия/тянуть', kind: 'measure', category: 'tools' },
    { label: 'Сохранение файла', kind: 'storage', category: 'storage' },
    { label: 'Сводка и отчёт', kind: 'report', category: 'report' }
  ],
  categories: [
    { category: 'modeling', count: 2 },
    { category: 'viewport', count: 2 },
    { category: 'tools', count: 2 },
    { category: 'storage', count: 1 },
    { category: 'report', count: 1 }
  ]
}

function mockPlan(profile) {
  const p = { ...mockPlanBase, profile }
  if (profile === 'large') {
    p.warning = 'Профиль large требует ~2 ГБ свободной RAM и несколько минут на сборку модели.'
    p.params = { ...mockPlanBase.params, targets: { instances: 8192, file_mb: 690 } }
  }
  return p
}

const mockResults = {
  meta: { sketchup_version: '27.0.123', profile: 'small', started_at: '2026-10-29 12:00' },
  run: { status: 'passed' },
  score: {
    overall: 1023.4,
    profile: 'small',
    status: 'passed',
    baseline: '2026-09-20 small',
    missing: ['storage']
  },
  groups: [
    {
      group: 'modeling', title: 'Моделирование',
      tests: [
        { id: 'diverse.asm_instantiation', name: 'Инстанцирование сборок', status: 'passed', unit: 'ms', value: 812, min: 795, max: 840, p95: 838, repeats: 3, ops: null, entities: 1024, error: null },
        { id: 'diverse.edit_open_close', name: 'Открытие/закрытие сборки', status: 'passed', unit: 'ms', value: 143, min: 138, max: 151, p95: 150, repeats: 3, ops: null, entities: 68, error: null }
      ]
    },
    {
      group: 'viewport', title: 'Вьюпорт',
      tests: [
        { id: 'poly.view_rotate', name: 'Вращение вьюпорта', status: 'passed', unit: 'fps', value: 58.2, min: 55.1, max: 60.0, p95: 55.9, repeats: 3, ops: null, entities: null, error: null },
        { id: 'poly.cyl_draw', name: 'Отрисовка цилиндров', status: 'failed', unit: 'ms', value: 214, min: 198, max: 240, p95: 239, repeats: 3, ops: null, entities: 3200, error: 'Порог превышен: 214 мс > 200 мс' }
      ]
    },
    {
      group: 'storage', title: 'Файл',
      tests: [
        { id: 'storage.save_500mb', name: 'Сохранение ~500 МБ', status: 'passed', unit: 'ms', value: 12400, min: 11900, max: 13100, p95: 13000, repeats: 2, ops: null, entities: null, error: null }
      ]
    }
  ]
}

const mockRuns = [
  { path: 'C:\\Users\\dn1desn\\Documents\\SketchUp Benchmarks\\bench-2026-10-29_120000.json', sketchup: '27.0.123', profile: 'small', started_at: '2026-10-29 12:00', suite: '4', tests: 12 },
  { path: 'C:\\Users\\dn1desn\\Documents\\SketchUp Benchmarks\\bench-2026-10-28_181500.json', sketchup: '27.0.123', profile: 'medium', started_at: '2026-10-28 18:15', suite: '4', tests: 12 },
  { path: 'C:\\Users\\dn1desn\\Documents\\SketchUp Benchmarks\\bench-2026-10-20_093000.json', sketchup: '26.0.456', profile: 'small', started_at: '2026-10-20 09:30', suite: '4', tests: 12 },
  { path: 'C:\\Users\\dn1desn\\Documents\\SketchUp Benchmarks\\bench-2026-10-12_110000.json', sketchup: '26.0.456', profile: 'small', started_at: '2026-10-12 11:00', suite: '3', tests: 10 }
]

const mockCompare = {
  warnings: ['Прогон 2026-10-12: другая версия набора (v3) — проценты не считаются'],
  columns: [
    { sketchup: '26.0.456', profile: 'small' },
    { sketchup: '27.0.123', profile: 'small' }
  ],
  scores: [
    { overall: 1000 },
    { overall: 1023.4, percent: 2.3 },
    null
  ],
  rows: [
    { group: 'modeling', name: 'Инстанцирование сборок', unit: 'ms', higher: false,
      cells: [{ value: 840 }, { value: 812, percent: -3.3 }, { incompatible: 'другая версия набора' }] },
    { group: 'viewport', name: 'Вращение вьюпорта', unit: 'fps', higher: true,
      cells: [{ value: 56.4 }, { value: 58.2, percent: 3.2 }, { value: null }] },
    { group: 'viewport', name: 'Отрисовка цилиндров', unit: 'ms', higher: false,
      cells: [{ value: 209 }, { value: 214, percent: 2.4 }, { value: null }] }
  ]
}

const mockSettings = { profile: 'small', iters: null, fps_s: null, wave_s: null, target_mb: null }

// Симуляция прогона: start → шаги с chunk/fps_tick → finish.
function runMockSequence() {
  const total = 6
  const steps = [
    'Сборка: сетка сборок',
    'Замер: инстанцирование',
    'Отрисовка цилиндров',
    'Замер: вращение (fps)',
    'Волна: полотно',
    'Сохранение файла'
  ]
  let t = 200
  later(() => receive('event', { event: 'start', profile: 'small', total }), t)
  steps.forEach((label, i) => {
    const idx = i + 1
    t += 300
    later(() => receive('event', { event: 'step', label, index: idx, total }), t)
    if (idx === 4) {
      // FPS-замер: несколько тиков
      for (let tick = 1; tick <= 3; tick++) {
        t += 400
        later(() => receive('event', { event: 'fps_tick', label, waited_s: (tick * 0.4).toFixed(1) }), t)
      }
    } else if (idx === 1 || idx === 6) {
      // тяжёлый шаг кусками
      for (let c = 1; c <= 3; c++) {
        t += 350
        later(() => receive('event', { event: 'chunk', label, done: c * 300, total: 900, phase: c, phases: 3 }), t)
      }
    }
    t += 250
    later(() => receive('event', {
      event: 'step_done', label, index: idx, total,
      result: idx === 5 ? '1893 мс' : null
    }), t)
  })
  t += 400
  later(() => receive('event', {
    event: 'finish', status: 'passed', errors: 0,
    json: 'C:\\…\\bench-mock.json', html: 'C:\\…\\bench-mock.html'
  }), t)
}

export function installMock() {
  window.sketchup = {
    get_overview() { later(() => receive('overview', mockOverview)) },
    get_settings() { later(() => receive('settings', mockSettings)) },
    get_plan(profile) { later(() => receive('plan', mockPlan(profile)), 250) },
    get_results() { later(() => receive('results', mockResults)) },
    get_runs() { later(() => receive('runs', { items: mockRuns })) },
    compare_runs() { later(() => receive('compare', mockCompare), 300) },
    save_settings() { later(() => receive('notice', { message: 'Настройки сохранены (mock)' })) },
    start_run() { runMockSequence() },
    cancel_run() { later(() => receive('notice', { message: 'Отмена запрошена — остановится после текущего теста (mock)' })) },
    open_path() { later(() => receive('notice', { message: 'open_path: папка отчётов (mock)' })) },
    open_last_report_path() { later(() => receive('notice', { message: 'open_last_report_path (mock)' })) }
  }
}
