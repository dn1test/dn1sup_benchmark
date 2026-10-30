/* dn1sup_benchmark — мост Ruby ↔ JS (Vue-порт ui/html/app.js).
 * Контракт: JS → Ruby: sketchup.<callback>(...); Ruby → JS:
 * window.bench.receive(channel, payload). С 0.7.1 набор один (без профилей
 * и настроек), блок сравнения прогонов убран: get_plan/start_run без
 * аргументов, каналы settings/runs/compare и колбэки get_runs/compare_runs
 * больше нет.
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

  results: null, // {none:true} | {meta, run, score, groups}

  // Разрешение вьюпорта FPS-замеров: один из ключей Runner::RESOLUTIONS
  resolution: 'hd',

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

export function refreshPlan() { call('get_plan', state.resolution) }

export function refreshResults() { call('get_results') }

export function startRun() { call('start_run', state.resolution) }

export function cancelRun() { call('cancel_run') }

export function openReports() {
  call('open_path', (state.overview && state.overview.reports_dir) || '', 'dir')
}

export function openLastReport() { call('open_last_report_path') }

/* Стартовая загрузка: обзор, план набора и результаты последнего прогона. */
export function bootstrap() {
  refreshOverview()
  refreshPlan()
  refreshResults()
}
