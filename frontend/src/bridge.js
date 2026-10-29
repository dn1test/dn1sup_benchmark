/* dn1sup_benchmark — мост Ruby ↔ JS (Vue-порт ui/html/app.js).
 * Контракт тот же, что и раньше (dialog.rb не меняется):
 *  — JS → Ruby: sketchup.<callback>(...), часть аргументов — JSON-строки;
 *  — Ruby → JS: window.bench.receive(channel, payload), 10 каналов.
 * Вне SketchUp (npm run dev в браузере) работает mock-режим (src/mocks.js). */

import { reactive } from 'vue'

function getSketchup() {
  if (typeof window === 'undefined') return null
  return window.sketchup || null
}

export const isMock = !getSketchup()

// -- реактивное состояние панели ----------------------------------------------

export const state = reactive({
  ready: false,

  overview: null, // {environment:{…, environment:{…}}, last_run, reports_dir}
  plan: null,     // {profile, warning, params, steps, …}
  running: false,

  runCounter: '0/0',
  runBarPct: 0,
  runCurrent: '—',
  runLog: [], // {kind: 'info'|'ok'|'err'|'done', text}

  results: null,    // {none:true} | {meta, run, score, groups}
  runs: [],         // [{path, sketchup, profile, started_at, suite, tests}]
  runsSelection: [], // выбранные для сравнения пути (v-model чекбоксов)
  compare: null,    // {warnings, columns, scores, rows}

  profile: 'small',
  // Переопределяемые скаляры (блок «Тесты», применяются и при запуске)
  overrides: { iters: '', fps_s: '', wave_s: '', target_mb: '' },
  // Параметры кастомного профиля (блок «Тесты»)
  custom: { diverse: '16', poly: '40', wave: '36', mb: '500' },

  notice: null // {kind: 'info'|'ok'|'err', text}
})

let noticeTimer = null
export function showNotice(text, kind = 'info', ms = 6000) {
  state.notice = text ? { kind, text } : null
  if (noticeTimer) clearTimeout(noticeTimer)
  if (state.notice) noticeTimer = setTimeout(() => { state.notice = null }, ms)
}

function pushLog(kind, text) {
  state.runLog.push({ kind, text })
  if (state.runLog.length > 400) state.runLog.splice(0, state.runLog.length - 400)
}

// -- payload переопределений (порт overrides(), ключи см. Runner::OVERRIDABLE) -

export function overridesPayload() {
  const o = {}
  const iters = String(state.overrides.iters || '').trim()
  const fps = String(state.overrides.fps_s || '').trim()
  const wave = String(state.overrides.wave_s || '').trim()
  const mb = String(state.overrides.target_mb || '').trim()
  if (iters) o.iters = parseInt(iters, 10)
  if (fps) o.fps_s = parseFloat(fps)
  if (wave) o.wave_s = parseFloat(wave)
  if (mb) o.target_mb = parseFloat(mb)
  if (state.profile === 'custom') {
    const dvg = parseInt(state.custom.diverse, 10) || 16
    const poly = parseInt(state.custom.poly, 10) || 40
    const wvg = parseInt(state.custom.wave, 10) || 36
    const tmb = parseFloat(state.custom.mb) || 500
    o.diverse = { grid: dvg, leaves: 4, leaf_defs: 24, asm_defs: 6 }
    o.poly = { n: poly, segments: 36 }
    o.wave = { grid: wvg }
    o.tools = { draw: 240, pushpull: 24, inst: 240, followme: 8, intersect: 16, paint: 240 }
    o.storage = { boxes: 1200, tex_size: 4096, max_tex: 24 }
    o.target_mb = tmb
    o.fps_s = o.fps_s || 2.0
    o.iters = o.iters || 3
    o.wave_s = o.wave_s || 8.0
    o.targets = { instances: dvg * dvg * 4, file_mb: tmb }
  }
  return o
}

// -- поток событий прогона (Sequencer → push 'event') --------------------------

function handleEvent(ev) {
  switch (ev.event) {
    case 'start':
      state.running = true
      state.runLog = []
      state.runBarPct = 0
      state.runCounter = '0/' + ev.total
      break
    case 'step':
      state.runCurrent = 'Шаг ' + ev.index + '/' + ev.total + ': ' + ev.label
      pushLog('info', '▶ ' + ev.label)
      break
    case 'fps_tick':
      state.runCurrent = ev.label + ' — замер кадров… (' + ev.waited_s + ' с)'
      break
    case 'chunk':
      state.runCurrent = ev.label + ' — ' + (ev.done || 0) + ' из ' +
        (ev.total || 0) + (ev.phases ? ' (фаза ' + ev.phase + '/' + ev.phases + ')' : '') +
        ' — можно отменить в любой момент'
      break
    case 'step_done':
      state.runCounter = ev.index + '/' + ev.total
      state.runBarPct = Math.round((ev.index / ev.total) * 100)
      pushLog('ok', '✔ ' + ev.label + (ev.result ? ' — ' + ev.result : ''))
      break
    case 'finish':
      state.running = false
      pushLog('done', '■ Готово: ' + (ev.status || ev.run_status || '') +
        (ev.errors !== undefined ? ', ошибок: ' + ev.errors : ''))
      showNotice('Прогон завершён. Отчёт: ' + (ev.html || ''), 'ok')
      refreshOverview()
      refreshResults()
      break
    case 'error':
      state.running = false
      pushLog('err', '✖ ' + ev.class + ': ' + ev.message)
      showNotice('Ошибка прогона: ' + ev.message, 'err')
      break
  }
}

// -- приём пушей Ruby (регистрируется до монтирования Vue) ---------------------

export function receive(channel, payload) {
  state.ready = true
  switch (channel) {
    case 'overview':
      state.overview = payload
      break
    case 'plan':
      state.plan = payload
      break
    case 'event':
      handleEvent(payload)
      break
    case 'results':
      state.results = payload
      break
    case 'runs':
      state.runs = (payload && payload.items) || []
      state.runsSelection = []
      break
    case 'compare':
      state.compare = payload
      break
    case 'settings':
      state.overrides = {
        iters: payload.iters ?? '',
        fps_s: payload.fps_s ?? '',
        wave_s: payload.wave_s ?? '',
        target_mb: payload.target_mb ?? ''
      }
      state.profile = payload.profile || 'small'
      refreshPlan()
      break
    case 'notice':
      showNotice(payload.message)
      break
    case 'error':
      showNotice('Ошибка: ' + payload.message, 'err')
      break
    case 'overview_error':
      showNotice(payload.message)
      break
  }
}

if (typeof window !== 'undefined') {
  window.bench = { receive }
}

// -- вызовы Ruby ----------------------------------------------------------------

function call(name, ...args) {
  const su = getSketchup()
  if (su && typeof su[name] === 'function') {
    try {
      su[name](...args)
      return true
    } catch (e) {
      console.warn('sketchup.' + name + ' не удался:', e)
    }
  }
  return false
}

export function refreshOverview() { call('get_overview') }

export function refreshPlan() {
  call('get_plan', state.profile, JSON.stringify(overridesPayload()))
}

export function refreshResults() { call('get_results') }

export function refreshRuns() { call('get_runs') }

export function startRun() {
  call('start_run', state.profile, JSON.stringify(overridesPayload()))
}

export function cancelRun() { call('cancel_run') }

export function compareSelected() {
  const paths = state.runsSelection
  if (paths.length < 2) {
    showNotice('Выберите минимум два прогона', 'err')
    return
  }
  call('compare_runs', JSON.stringify(paths))
}

export function saveSettings() {
  call('save_settings', JSON.stringify(overridesPayload()))
}

export function openReports() {
  call('open_path', (state.overview && state.overview.reports_dir) || '', 'dir')
}

export function openLastReport() { call('open_last_report_path') }

/* Стартовая загрузка (порт DOMContentLoaded-бутстрапа app.js): обзор, настройки
 * (их обработчик сам запрашивает план), план для выбранного профиля и данные
 * правой страницы — результаты и список прогонов для сравнения. */
export function bootstrap() {
  refreshOverview()
  call('get_settings')
  refreshPlan()
  refreshResults()
  refreshRuns()
}
