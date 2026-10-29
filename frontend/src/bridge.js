/* dn1sup_benchmark — мост Ruby ↔ JS (Vue-порт ui/html/app.js).
 * Контракт тот же, что и раньше (dialog.rb не менялся до 0.7.0):
 *  — JS → Ruby: sketchup.<callback>(...), часть аргументов — JSON-строки;
 *  — Ruby → JS: window.bench.receive(channel, payload), 10 каналов.
 * С 0.7.0 набор один (без профилей и настроек): get_plan/start_run без
 * аргументов, каналы settings нет.
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
    case 'runs':
      state.runs = (payload && payload.items) || []
      state.runsSelection = []
      break
    case 'compare':
      state.compare = payload
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

export function refreshPlan() { call('get_plan') }

export function refreshResults() { call('get_results') }

export function refreshRuns() { call('get_runs') }

export function startRun() { call('start_run') }

export function cancelRun() { call('cancel_run') }

export function compareSelected() {
  const paths = state.runsSelection
  if (paths.length < 2) {
    showNotice('Выберите минимум два прогона', 'err')
    return
  }
  call('compare_runs', JSON.stringify(paths))
}

export function openReports() {
  call('open_path', (state.overview && state.overview.reports_dir) || '', 'dir')
}

export function openLastReport() { call('open_last_report_path') }

/* Стартовая загрузка (порт DOMContentLoaded-бутстрапа app.js): обзор, план
 * набора и данные правой страницы — результаты и список прогонов. */
export function bootstrap() {
  refreshOverview()
  refreshPlan()
  refreshResults()
  refreshRuns()
}
