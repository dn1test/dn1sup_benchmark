<script setup>
import { computed } from 'vue'
import { FileText, RefreshCw } from 'lucide-vue-next'
import { state, refreshResults, openLastReport } from '../bridge'
import { fmt } from '../format'
import StatusBadge from './StatusBadge.vue'

const results = computed(() => state.results)
const score = computed(() => (results.value && results.value.score) || null)
const missing = computed(() =>
  score.value && Array.isArray(score.value.missing) && score.value.missing.length
    ? score.value.missing.join(', ')
    : ''
)
</script>

<template>
  <div>
    <div class="mb-2 flex gap-2">
      <button class="ss-btn-ghost !py-1 text-xs" @click="refreshResults">
        <RefreshCw :size="14" /> Обновить
      </button>
      <button class="ss-btn-ghost !py-1 text-xs" @click="openLastReport">
        <FileText :size="14" /> HTML-отчёт
      </button>
    </div>

    <div v-if="!results || results.none" class="text-xs text-slate-500 dark:text-slate-400">
      Нет данных — запустите прогон.
    </div>

    <template v-else>
      <div class="mb-1 text-xs text-slate-500 dark:text-slate-400">
        SU {{ results.meta.sketchup_version }} · {{ results.meta.profile }} ·
        {{ (results.run && results.run.status) || '' }} · {{ results.meta.started_at }}
      </div>

      <div
        v-if="score && score.overall"
        class="my-1 flex flex-wrap items-baseline gap-x-2 gap-y-1 rounded-lg bg-slate-200/60 px-3 py-2 dark:bg-slate-800/60"
      >
        <span class="text-xl font-semibold">{{ Math.round(score.overall) }}</span>
        <span class="text-xs text-slate-500 dark:text-slate-400">
          общий балл профиля {{ score.profile }} ({{ score.status }}; 1000 = базовый прогон
          {{ score.baseline }}); необязательная сводка, разг. оценки ниже — основная часть
        </span>
        <span v-if="missing" class="text-xs text-red-500 dark:text-red-400">не учтены: {{ missing }}</span>
      </div>
      <div v-else-if="score && score.reason" class="my-1 text-xs text-slate-500 dark:text-slate-400">
        Общий балл: {{ score.reason }}
      </div>

      <template v-for="g in results.groups || []" :key="g.group">
        <div class="mt-2 font-semibold">{{ g.title }}</div>
        <div class="overflow-x-auto">
          <table class="bench-table">
            <thead>
              <tr>
                <th>Тест</th><th>Статус</th><th class="num">Значение</th><th class="num">min</th>
                <th class="num">max</th><th class="num">p95</th><th class="num">Повт.</th>
                <th class="num">оп/с</th><th class="num">Сущн.</th>
              </tr>
            </thead>
            <tbody>
              <template v-for="r in g.tests" :key="r.id">
                <tr>
                  <td>{{ r.name }}</td>
                  <td><StatusBadge :status="r.status" /></td>
                  <td class="num font-semibold">{{ fmt(r.value, r.unit) }}</td>
                  <td class="num">{{ fmt(r.min, r.unit) }}</td>
                  <td class="num">{{ fmt(r.max, r.unit) }}</td>
                  <td class="num">{{ fmt(r.p95, r.unit) }}</td>
                  <td class="num">{{ r.repeats === null ? '—' : r.repeats }}</td>
                  <td class="num">{{ r.ops === null || r.ops === undefined ? '—' : r.ops }}</td>
                  <td class="num">{{ r.entities === null ? '—' : r.entities }}</td>
                </tr>
                <tr v-if="r.error">
                  <td colspan="9" class="text-xs text-red-500 dark:text-red-400">{{ r.error }}</td>
                </tr>
              </template>
            </tbody>
          </table>
        </div>
      </template>
    </template>
  </div>
</template>
