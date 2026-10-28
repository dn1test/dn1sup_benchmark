/* dn1sup_benchmark/ui/html/app.js — логика панели (ванильный JS, без CDN).
 * Мост: sketchup.<callback>(...) → Ruby; Ruby → window.bench.receive(channel, payload). */
(function () {
  'use strict';

  var state = {
    profile: 'small',
    plan: null,
    running: false,
    lastRunsSelection: []
  };

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s === null || s === undefined ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function fmt(v, unit) {
    if (v === null || v === undefined) return '—';
    if (unit === 'fps') return Number(v).toFixed(1) + ' fps';
    var n = Number(v);
    return n >= 1000 ? (n / 1000).toFixed(2) + ' с' : n.toFixed(1) + ' мс';
  }

  function statusBadge(st) {
    return '<span class="badge badge-status-' + esc(st) + '">' + esc(st) + '</span>';
  }

  function notice(msg) {
    var el = $('notice');
    if (!msg) { el.classList.add('d-none'); return; }
    el.textContent = msg;
    el.classList.remove('d-none');
    setTimeout(function () { el.classList.add('d-none'); }, 6000);
  }

  /* ---------------- вкладки ---------------- */

  function showTab(id) {
    ['tab-overview', 'tab-tests', 'tab-run', 'tab-results', 'tab-compare', 'tab-settings'].forEach(function (t) {
      $(t).classList.toggle('d-none', t !== id);
    });
    Array.prototype.forEach.call(document.querySelectorAll('#tabs .nav-link'), function (a) {
      a.classList.toggle('active', a.getAttribute('data-tab') === id);
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll('#tabs .nav-link'), function (a) {
    a.addEventListener('click', function (ev) {
      ev.preventDefault();
      showTab(a.getAttribute('data-tab'));
      if (a.getAttribute('data-tab') === 'tab-results') bench.refreshResults();
      if (a.getAttribute('data-tab') === 'tab-compare') bench.refreshRuns();
    });
  });

  /* ---------------- Обзор ---------------- */

  function renderOverview(d) {
    state.reportsDir = d.reports_dir || '';
    var meta = d.environment || {};
    var env = meta.environment || {};
    var vp = env.viewport || {};
    var rows = [
      ['SketchUp', (meta.sketchup_version || '?') + ' (' + (meta.version_number || '') + ')'],
      ['Ruby', meta.ruby_version],
      ['ОС / платформа', meta.os + ' / ' + meta.platform],
      ['CPU', (meta.cpu || '?') + ' × ' + (meta.cores || '?')],
      ['Масштаб DPI', env.ui_scale_factor],
      ['Вьюпорт', vp.width ? vp.width + '×' + vp.height : null],
      ['GPU-движок', 'недоступно через API (null)'],
      ['Набор тестов', 'v' + meta.test_suite_version + ', схема v' + meta.schema_version]
    ];
    $('env-table').innerHTML = rows.map(function (r) {
      return '<tr><th>' + esc(r[0]) + '</th><td>' + esc(r[1] === null || r[1] === undefined ? '—' : r[1]) + '</td></tr>';
    }).join('');
    $('ver').textContent = 'v' + meta.benchmark_version;

    var lr = d.last_run;
    if (!lr) { $('last-run').textContent = 'Прогонов пока не было.'; return; }
    var runSt = (lr.run && lr.run.status) || '?';
    var scoreHtml = '';
    if (lr.score && lr.score.overall) {
      scoreHtml = '<div class="my-1"><span class="h5 mb-0"><b>' + Math.round(lr.score.overall) +
        '</b></span> <span class="text-secondary small">общий балл (' + esc(lr.score.status) +
        '; 1000 = база)</span></div>';
    } else if (lr.score && lr.score.reason) {
      scoreHtml = '<div class="text-secondary small my-1">Балл: ' + esc(lr.score.reason) + '</div>';
    }
    $('last-run').innerHTML =
      'SU ' + esc(lr.sketchup) + ', профиль ' + esc(lr.profile) + ' — ' + esc(runSt) +
      ' (' + esc(lr.file) + ')<br>Тестов: ' + lr.tests + ', не пройдено: ' + lr.not_passed +
      scoreHtml +
      '<table class="table table-sm bench-table mt-1 mb-0">' +
      '<tr><th>Тест</th><th>Статус</th><th class="num">Значение</th></tr>' +
      lr.results.slice(0, 8).map(function (r) {
        return '<tr><td class="mono">' + esc(r.id) + '</td><td>' + statusBadge(r.status) +
               '</td><td class="num">' + esc(fmt(r.value, r.unit)) + '</td></tr>';
      }).join('') +
      (lr.results.length > 8 ? '<tr><td colspan="3" class="text-secondary">…и ещё ' + (lr.results.length - 8) + '</td></tr>' : '') +
      '</table>';
  }

  /* ---------------- Тесты / план ---------------- */

  function overrides() {
    var o = {};
    var iters = $('st-iters').value.trim();
    var fps = $('st-fps').value.trim();
    if (iters) o.iters = parseInt(iters, 10);
    if (fps) o.fps_s = parseFloat(fps);
    o.doc_enabled = $('st-doc').checked;
    if (state.profile === 'custom') {
      o.grid = { n: parseInt($('cu-grid-n').value, 10) || 70 };
      o.components = { defs: parseInt($('cu-defs').value, 10) || 10, assemblies: 6, per_assembly: 4,
                       grid: parseInt($('cu-comp-grid').value, 10) || 10 };
      o.nested = { depth: 6, items: 4 };
      o.textured = { boxes: parseInt($('cu-boxes').value, 10) || 24 };
      o.api01_loops = parseInt($('cu-loops').value, 10) || 2500;
      o.api02_groups = 100;
      o.api03_defs = parseInt($('cu-defs').value, 10) || 10;
      o.api03_instances = (o.components.grid || 10) * (o.components.grid || 10);
      o.api05_objects = 100;
      o.api06_faces = parseInt($('cu-tx').value, 10) || 100;
      o.pushpull = 8; o.move = 10; o.add_faces = 8; o.tex_apply = 60;
      o.targets = { edges: o.api01_loops * 4, instances: o.api03_instances };
    }
    return o;
  }

  function renderPlan(p) {
    state.plan = p;
    var warn = $('profile-warning');
    if (p.warning) { warn.textContent = p.warning; warn.classList.remove('d-none'); }
    else warn.classList.add('d-none');

    var pr = p.params || {};
    var tg = pr.targets || {};
    $('plan-params').innerHTML =
      'Цели: ~' + esc(tg.edges) + ' рёбер, ~' + esc(tg.instances) + ' инстансов; ' +
      'сетка ' + esc((pr.grid || {}).n) + '×' + esc((pr.grid || {}).n) + '; ' +
      'повторов: ' + esc(pr.iters) + '; FPS-замер: ' + esc(pr.fps_s) + ' с; ' +
      'DOC-тесты: ' + (pr.doc_enabled ? 'вкл' : 'выкл');
    $('plan-steps').innerHTML =
      '<tr><th>Шаг</th><th>Категория</th></tr>' +
      p.steps.map(function (s) {
        return '<tr><td>' + esc(s.label || s.kind) + '</td><td>' + esc(s.category || '—') + '</td></tr>';
      }).join('');
    $('run-load-summary').textContent = 'Профиль ' + p.profile + ': ~' + esc(tg.edges) +
      ' рёбер, ~' + esc(tg.instances) + ' инстансов, ' + p.steps.length + ' шагов.';
  }

  /* ---------------- Запуск ---------------- */

  function setRunning(running) {
    state.running = running;
    $('run-badge').classList.toggle('d-none', !running);
    $('run-start-block').classList.toggle('d-none', running);
    $('run-progress-block').classList.toggle('d-none', !running);
  }

  function appendLog(line) {
    var el = $('run-log');
    var div = document.createElement('div');
    div.textContent = line;
    el.appendChild(div);
    el.scrollTop = el.scrollHeight;
  }

  function handleEvent(ev) {
    switch (ev.event) {
      case 'start':
        setRunning(true);
        $('run-log').innerHTML = '';
        $('run-bar').style.width = '0%';
        $('run-counter').textContent = '0/' + ev.total;
        showTab('tab-run');
        break;
      case 'step':
        $('run-current').textContent = 'Шаг ' + ev.index + '/' + ev.total + ': ' + ev.label;
        appendLog('▶ ' + ev.label);
        break;
      case 'fps_tick':
        $('run-current').textContent = ev.label + ' — замер кадров… (' + ev.waited_s + ' с)';
        break;
      case 'chunk':
        $('run-current').textContent = ev.label + ' — ' + (ev.done || 0) + ' из ' +
          (ev.total || 0) + (ev.phases ? ' (фаза ' + ev.phase + '/' + ev.phases + ')' : '') +
          ' — можно отменить в любой момент';
        break;
      case 'step_done':
        $('run-counter').textContent = ev.index + '/' + ev.total;
        $('run-bar').style.width = Math.round((ev.index / ev.total) * 100) + '%';
        appendLog('✔ ' + ev.label + (ev.result ? ' — ' + ev.result : ''));
        break;
      case 'finish':
        setRunning(false);
        appendLog('■ Готово: ' + (ev.status || ev.run_status || '') + (ev.errors !== undefined ? ', ошибок: ' + ev.errors : ''));
        notice('Прогон завершён. Отчёт: ' + (ev.html || ''));
        bench.refreshOverview();
        bench.refreshResults();
        showTab('tab-results');
        break;
      case 'error':
        setRunning(false);
        appendLog('✖ ' + ev.class + ': ' + ev.message);
        notice('Ошибка прогона: ' + ev.message);
        break;
    }
  }

  /* ---------------- Результаты ---------------- */

  function renderResults(d) {
    if (!d || d.none) { $('results-body').textContent = 'Нет данных — запустите прогон.'; return; }
    var m = d.meta || {};
    var html = '<div class="mb-1">SU ' + esc(m.sketchup_version) + ' · ' + esc(m.profile) + ' · ' +
               esc((d.run && d.run.status) || '') + ' · ' + esc(m.started_at) + '</div>';
    if (d.score) {
      if (d.score.overall) {
        html += '<div class="alert alert-secondary py-2 px-3 my-1 d-flex align-items-baseline gap-2">' +
          '<span class="h4 mb-0"><b>' + Math.round(d.score.overall) + '</b></span>' +
          '<span class="small">общий балл профиля ' + esc(d.score.profile) + ' (' + esc(d.score.status) +
          '; 1000 = базовый прогон ' + esc(d.score.baseline) + '); необязательная сводка, ' +
          'разг. оценки ниже — основная часть</span>';
        if (d.score.missing && d.score.missing.length) {
          html += '<span class="text-danger small">не учтены: ' + esc(d.score.missing.join(', ')) + '</span>';
        }
        html += '</div>';
      } else if (d.score.reason) {
        html += '<div class="text-secondary small my-1">Общий балл: ' + esc(d.score.reason) + '</div>';
      }
    }
    (d.groups || []).forEach(function (g) {
      html += '<div class="fw-bold mt-2">' + esc(g.title) + '</div>' +
        '<table class="table table-sm bench-table"><tr>' +
        '<th>Тест</th><th>Статус</th><th class="num">Значение</th><th class="num">min</th>' +
        '<th class="num">max</th><th class="num">p95</th><th class="num">Повт.</th>' +
        '<th class="num">оп/с</th><th class="num">Сущн.</th></tr>';
      g.tests.forEach(function (r) {
        html += '<tr><td>' + esc(r.name) + '</td><td>' + statusBadge(r.status) + '</td>' +
          '<td class="num"><b>' + esc(fmt(r.value, r.unit)) + '</b></td>' +
          '<td class="num">' + esc(fmt(r.min, r.unit)) + '</td>' +
          '<td class="num">' + esc(fmt(r.max, r.unit)) + '</td>' +
          '<td class="num">' + esc(fmt(r.p95, r.unit)) + '</td>' +
          '<td class="num">' + esc(r.repeats === null ? '—' : r.repeats) + '</td>' +
          '<td class="num">' + esc(r.ops === null || r.ops === undefined ? '—' : r.ops) + '</td>' +
          '<td class="num">' + esc(r.entities === null ? '—' : r.entities) + '</td></tr>';
        if (r.error) html += '<tr><td colspan="9" class="text-danger small">' + esc(r.error) + '</td></tr>';
      });
      html += '</table>';
    });
    $('results-body').innerHTML = html;
  }

  /* ---------------- Сравнение ---------------- */

  function renderRuns(items) {
    if (!items.length) { $('runs-list').textContent = 'Сохранённых прогонов нет.'; return; }
    $('runs-list').innerHTML = items.map(function (r, i) {
      return '<div class="form-check">' +
        '<input class="form-check-input run-check" type="checkbox" id="run-' + i + '" data-path="' + esc(r.path) + '">' +
        '<label class="form-check-label small" for="run-' + i + '">' + esc(r.sketchup) + ' · ' +
        esc(r.profile) + ' · ' + esc(r.started_at) + ' · набор v' + esc(r.suite || '?') +
        ' (' + r.tests + ' тестов)</label></div>';
    }).join('');
  }

  function renderCompare(d) {
    var html = '';
    (d.warnings || []).forEach(function (w) {
      html += '<div class="alert alert-warning py-1 px-2 small">' + esc(w) + '</div>';
    });
    if (d.scores && d.scores.length) {
      html += '<table class="table table-sm bench-table"><tr><th>Общий балл</th>';
      d.columns.forEach(function (c) {
        html += '<th class="num">' + esc(c.sketchup) + ' ' + esc(c.profile) + '</th>';
      });
      html += '</tr><tr><td class="small text-secondary">1000 = базовый прогон</td>';
      d.scores.forEach(function (s, i) {
        if (!s || s.overall === null || s.overall === undefined) {
          html += '<td class="num text-secondary">' + esc((s && s.reason) || '—') + '</td>';
          return;
        }
        var cell = '<b>' + Math.round(s.overall) + '</b>';
        if (i > 0 && s.percent !== undefined) {
          var cls = Math.abs(s.percent) < 3 ? 'text-secondary' : (s.percent > 0 ? 'text-success' : 'text-danger');
          cell += ' <span class="' + cls + ' small">' + (s.percent >= 0 ? '+' : '') + s.percent + '%</span>';
        } else if (i > 0 && s.incompatible) {
          cell += ' <span class="text-secondary small" title="' + esc(s.incompatible) + '">несравнимо</span>';
        }
        html += '<td class="num' + (i === 0 ? ' table-active' : '') + '">' + cell + '</td>';
      });
      html += '</tr></table>';
    }
    var groups = {};
    d.rows.forEach(function (r) { (groups[r.group] = groups[r.group] || []).push(r); });
    Object.keys(groups).forEach(function (g) {
      html += '<div class="fw-bold mt-2">' + esc(g) + '</div><table class="table table-sm bench-table"><tr><th>Тест</th>';
      d.columns.forEach(function (c) {
        html += '<th class="num">' + esc(c.sketchup) + ' ' + esc(c.profile) + '</th>';
      });
      html += '</tr>';
      groups[g].forEach(function (r) {
        html += '<tr><td>' + esc(r.name) + '</td>';
        r.cells.forEach(function (c, i) {
          if (c.value === null || c.value === undefined) { html += '<td class="num text-secondary">—</td>'; return; }
          var cell = '<b>' + esc(fmt(c.value, r.unit)) + '</b>';
          if (i > 0 && c.percent !== undefined) {
            var cls = Math.abs(c.percent) < 3 ? 'text-secondary'
              : ((r.higher ? c.percent > 0 : c.percent < 0) ? 'text-success' : 'text-danger');
            cell += ' <span class="' + cls + ' small">' + (c.percent >= 0 ? '+' : '') + c.percent + '%</span>';
          } else if (i > 0 && c.incompatible) {
            cell += ' <span class="text-secondary small" title="' + esc(c.incompatible) + '">несравнимо</span>';
          }
          html += '<td class="num' + (i === 0 ? ' table-active' : '') + '">' + cell + '</td>';
        });
        html += '</tr>';
      });
      html += '</table>';
    });
    $('compare-body').innerHTML = html;
  }

  /* ---------------- API для onclick и Ruby ---------------- */

  window.bench = {
    receive: function (channel, payload) {
      switch (channel) {
        case 'overview': renderOverview(payload); break;
        case 'plan': renderPlan(payload); break;
        case 'event': handleEvent(payload); break;
        case 'results': renderResults(payload); break;
        case 'runs': renderRuns(payload.items || []); break;
        case 'compare': renderCompare(payload); break;
        case 'settings':
          $('st-profile').value = payload.profile || 'small';
          $('st-iters').value = payload.iters || '';
          $('st-fps').value = payload.fps_s || '';
          $('st-doc').checked = payload.doc_enabled !== false;
          state.profile = $('st-profile').value;
          $('profile-select').value = state.profile;
          $('custom-fields').classList.toggle('d-none', state.profile !== 'custom');
          bench.refreshPlan();
          break;
        case 'notice': notice(payload.message); break;
        case 'error': notice('Ошибка: ' + payload.message); break;
        case 'overview_error': notice(payload.message); break;
      }
    },
    refreshOverview: function () { sketchup.get_overview(); },
    refreshPlan: function () { sketchup.get_plan(state.profile, JSON.stringify(overrides())); },
    refreshResults: function () { sketchup.get_results(); },
    refreshRuns: function () { sketchup.get_runs(); },
    toRun: function () {
      bench.refreshPlan();
      showTab('tab-run');
    },
    startRun: function () {
      sketchup.start_run(state.profile, JSON.stringify(overrides()));
    },
    cancelRun: function () { sketchup.cancel_run(); },
    compareSelected: function () {
      var paths = Array.prototype.map.call(document.querySelectorAll('.run-check:checked'), function (c) {
        return c.getAttribute('data-path');
      });
      if (paths.length < 2) { notice('Выберите минимум два прогона'); return; }
      sketchup.compare_runs(JSON.stringify(paths));
    },
    saveSettings: function () {
      sketchup.save_settings(JSON.stringify(overrides()));
    },
    openReports: function () {
      sketchup.open_path(state.reportsDir || '', 'dir');
    },
    openLastReport: function () { sketchup.open_last_report_path(); }
  };

  $('profile-select').addEventListener('change', function () {
    state.profile = this.value;
    $('custom-fields').classList.toggle('d-none', this.value !== 'custom');
    bench.refreshPlan();
  });

  /* Стартовая загрузка: Ruby вызывает bench.receive('overview'|'settings') после ready. */
  document.addEventListener('DOMContentLoaded', function () {
    sketchup.get_overview();
    sketchup.get_settings();
    sketchup.get_plan('small', '{}');
  });
})();
