<script setup>
import { computed } from 'vue'
import { Save } from 'lucide-vue-next'
import { state, refreshPlan, saveSettings } from '../bridge'

const PROFILES = [
  { value: 'small', label: 'small — ~1 тыс. инстансов / файл 500 МБ' },
  { value: 'medium', label: 'medium — ~2,3 тыс. / файл 500 МБ' },
  { value: 'large', label: 'large — ~8,2 тыс. инстансов, ~690 тыс. треугольников' },
  { value: 'custom', label: 'custom — свои параметры' }
]

const plan = computed(() => state.plan)

const planParams = computed(() => {
  const p = plan.value
  if (!p || !p.params) return '—'
  const pr = p.params
  const tg = pr.targets || {}
  const dv = pr.diverse || {}
  const po = pr.poly || {}
  const wv = pr.wave || {}
  const n = parseInt(po.n, 10) || 0
  const seg = parseInt(po.segments, 10) || 0
  return 'Моделирование: ' + dv.grid + '² сборок × ' + dv.leaves + ' листьев (~' + tg.instances +
    ' инстансов); вьюпорт: ' + po.n + '² цилиндров (' + po.segments +
    ' сегм., ~' + Math.round(n * n * (2 * seg + 2) / 1000) + ' тыс. треугольников); волна: ' +
    wv.grid + '² кубов, ' + pr.wave_s + ' с; файл: ~' + pr.target_mb +
    ' МБ; повторы: ' + pr.iters + '; FPS-замер: ' + pr.fps_s + ' с.'
})
</script>

<template>
  <div class="grid grid-cols-[minmax(0,250px)_1fr] gap-3">
    <!-- Параметры нагрузки и прогона -->
    <div class="min-w-0">
      <label class="ss-label mb-1 block">Профиль нагрузки</label>
      <select v-model="state.profile" class="ss-input !py-1 text-xs" @change="refreshPlan">
        <option v-for="p in PROFILES" :key="p.value" :value="p.value">{{ p.label }}</option>
      </select>

      <div v-if="state.profile === 'custom'" class="mt-2 grid grid-cols-2 gap-1.5 text-xs">
        <div>
          <label class="mb-0.5 block text-slate-500 dark:text-slate-400">Сетка сборок (n²)</label>
          <input v-model="state.custom.diverse" class="ss-input !py-1">
        </div>
        <div>
          <label class="mb-0.5 block text-slate-500 dark:text-slate-400">Цилиндров n²</label>
          <input v-model="state.custom.poly" class="ss-input !py-1">
        </div>
        <div>
          <label class="mb-0.5 block text-slate-500 dark:text-slate-400">Волна: полотно n²</label>
          <input v-model="state.custom.wave" class="ss-input !py-1">
        </div>
        <div>
          <label class="mb-0.5 block text-slate-500 dark:text-slate-400">Файл, МБ</label>
          <input v-model="state.custom.mb" class="ss-input !py-1">
        </div>
        <div class="col-span-2 text-[11px] text-slate-400 dark:text-slate-500">
          Остальные параметры берутся из профиля small.
        </div>
      </div>

      <label class="ss-label mb-1 mt-3 block">Переопределения (пусто = по профилю)</label>
      <div class="space-y-1.5">
        <input v-model="state.overrides.iters" class="ss-input !py-1 text-xs" placeholder="Повторов на тест, напр. 3">
        <input v-model="state.overrides.fps_s" class="ss-input !py-1 text-xs" placeholder="Секунд на FPS-замер, напр. 2.0">
        <input v-model="state.overrides.wave_s" class="ss-input !py-1 text-xs" placeholder="Секунд на волну, напр. 8">
        <input v-model="state.overrides.target_mb" class="ss-input !py-1 text-xs" placeholder="Цель файла, МБ (по умолчанию 500)">
        <button class="ss-btn-ghost !py-1 text-xs" @click="saveSettings">
          <Save :size="14" /> Сохранить по умолчанию
        </button>
      </div>

      <div
        v-if="plan && plan.warning"
        class="mt-2 rounded-lg bg-amber-50 px-2 py-1.5 text-xs text-amber-800 dark:bg-amber-950/50 dark:text-amber-300"
      >{{ plan.warning }}</div>
    </div>

    <!-- План -->
    <div class="min-w-0 rounded-lg border border-slate-200 p-2.5 dark:border-slate-800">
      <h3 class="ss-label mb-2">Нагрузка и план</h3>
      <div class="mb-2 text-xs leading-5 text-slate-600 dark:text-slate-300">{{ planParams }}</div>
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
