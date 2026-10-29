<script setup>
import { computed } from 'vue'
import { state } from '../bridge'

const plan = computed(() => state.plan)

const planParams = computed(() => {
  const p = plan.value
  if (!p || !p.params) return '—'
  const pr = p.params
  const tg = pr.targets || {}
  const dv = pr.diverse || {}
  const po = pr.poly || {}
  const wv = pr.wave || {}
  const st = pr.storage || {}
  const n = parseInt(po.n, 10) || 0
  const seg = parseInt(po.segments, 10) || 0
  return 'Моделирование: ' + dv.grid + '² сборок × ' + dv.leaves + ' листьев (~' + tg.instances +
    ' инстансов); вьюпорт: ' + po.n + '² цилиндров (' + po.segments +
    ' сегм., ~' + Math.round(n * n * (2 * seg + 2) / 1000) + ' тыс. треугольников); волна: ' +
    wv.grid + '² кубов, ' + pr.wave_s + ' с; файл: ~' + pr.target_mb +
    ' МБ (' + st.boxes + ' тел + текстуры ' + st.tex_size + '²); повторы: ' + pr.iters +
    '; FPS-замер: ' + pr.fps_s + ' с.'
})
</script>

<template>
  <div>
    <div class="mb-2 text-xs text-slate-500 dark:text-slate-400">
      Набор один, без выбора: 5 категорий, полный прогон ~1 минута.
    </div>
    <div class="rounded-lg border border-slate-200 p-2.5 dark:border-slate-800">
      <h3 class="ss-label mb-2">Нагрузка и план</h3>
      <div class="mb-2 text-xs leading-5 text-slate-600 dark:text-slate-300">{{ planParams }}</div>
      <div
        v-if="plan && plan.warning"
        class="mb-2 rounded-lg bg-amber-50 px-2 py-1.5 text-xs text-amber-800 dark:bg-amber-950/50 dark:text-amber-300"
      >{{ plan.warning }}</div>
      <table v-if="plan && plan.steps" class="bench-table">
        <thead>
          <tr><th>Шаг</th><th>Категория</th></tr>
        </thead>
        <tbody>
          <tr v-for="(s, i) in plan.steps" :key="i">
            <td>{{ s.label || s.kind }}</td>
            <td>{{ s.category || '—' }}</td>
          </tr>
        </tbody>
      </table>
      <div v-else class="text-xs text-slate-400">План загружается…</div>
    </div>
  </div>
</template>
