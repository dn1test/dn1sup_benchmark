<script setup>
import { computed } from 'vue'
import { GitCompare, RefreshCw } from 'lucide-vue-next'
import { state, refreshRuns, compareSelected } from '../bridge'
import { fmt, pctClass, pctText } from '../format'

const compare = computed(() => state.compare)

// Группировка строк сравнения по группе, как в renderCompare
const groups = computed(() => {
  const cmp = compare.value
  if (!cmp || !cmp.rows) return []
  const order = []
  const map = {}
  cmp.rows.forEach((r) => {
    if (!map[r.group]) {
      map[r.group] = []
      order.push(r.group)
    }
    map[r.group].push(r)
  })
  return order.map((g) => ({ title: g, rows: map[g] }))
})

function overallCellCls(i) {
  return i === 0 ? 'num bg-slate-200/60 dark:bg-slate-800/60' : 'num'
}
</script>

<template>
  <div>
    <div class="mb-1 text-xs text-slate-500 dark:text-slate-400">
      Сравнимы только прогоны с одинаковыми версией теста, единицами и параметрами нагрузки
      (несовместимые помечаются, проценты не считаются).
    </div>

    <div class="flex items-start gap-2">
      <div class="max-h-40 min-w-0 flex-1 overflow-y-auto rounded-lg border border-slate-200 p-2 dark:border-slate-800">
        <div v-if="!state.runs.length" class="text-xs text-slate-500 dark:text-slate-400">
          Сохранённых прогонов нет.
        </div>
        <label
          v-for="(r, i) in state.runs"
          :key="r.path"
          class="flex cursor-pointer items-start gap-2 py-0.5 text-xs text-slate-600 dark:text-slate-300"
        >
          <input v-model="state.runsSelection" type="checkbox" :value="r.path" class="mt-0.5">
          <span>{{ r.sketchup }} · {{ r.profile }} · {{ r.started_at }} · набор v{{ r.suite || '?' }}
            ({{ r.tests }} тестов)</span>
        </label>
      </div>
      <div class="flex flex-col gap-1.5">
        <button class="ss-btn-primary !py-1 text-xs" @click="compareSelected">
          <GitCompare :size="14" /> Сравнить (2+)
        </button>
        <button class="ss-btn-ghost !py-1 text-xs" @click="refreshRuns">
          <RefreshCw :size="14" /> Обновить
        </button>
      </div>
    </div>

    <div v-if="compare" class="mt-2">
      <div
        v-for="(w, i) in compare.warnings || []"
        :key="i"
        class="mb-1 rounded-lg bg-amber-50 px-2 py-1 text-xs text-amber-800 dark:bg-amber-950/50 dark:text-amber-300"
      >{{ w }}</div>

      <!-- Общие баллы -->
      <div v-if="compare.scores && compare.scores.length" class="overflow-x-auto">
        <table class="bench-table">
        <thead>
          <tr>
            <th>Общий балл</th>
            <th v-for="(c, i) in compare.columns" :key="i" class="num">{{ c.sketchup }} {{ c.profile }}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td class="text-xs text-slate-400 dark:text-slate-500">1000 = базовый прогон</td>
            <td
              v-for="(s, i) in compare.scores"
              :key="i"
              :class="overallCellCls(i)"
            >
              <template v-if="!s || s.overall === null || s.overall === undefined">
                {{ (s && s.reason) || '—' }}
              </template>
              <template v-else>
                <b>{{ Math.round(s.overall) }}</b>
                <span
                  v-if="i > 0 && s.percent !== undefined"
                  class="ml-1 text-xs"
                  :class="pctClass(s.percent, true)"
                >{{ pctText(s.percent) }}</span>
                <span
                  v-else-if="i > 0 && s.incompatible"
                  class="ml-1 text-xs text-slate-400 dark:text-slate-500"
                  :title="s.incompatible"
                >несравнимо</span>
              </template>
            </td>
          </tr>
        </tbody>
      </table>
      </div>

      <!-- Группы -->
      <template v-for="g in groups" :key="g.title">
        <div class="mt-2 font-semibold">{{ g.title }}</div>
        <div class="overflow-x-auto">
          <table class="bench-table">
            <thead>
              <tr>
                <th>Тест</th>
                <th v-for="(c, i) in compare.columns" :key="i" class="num">{{ c.sketchup }} {{ c.profile }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in g.rows" :key="r.name">
                <td>{{ r.name }}</td>
                <td
                  v-for="(c, i) in r.cells"
                  :key="i"
                  :class="overallCellCls(i)"
                >
                  <template v-if="c.value === null || c.value === undefined">—</template>
                  <template v-else>
                    <b>{{ fmt(c.value, r.unit) }}</b>
                    <span
                      v-if="i > 0 && c.percent !== undefined"
                      class="ml-1 text-xs"
                      :class="pctClass(c.percent, r.higher)"
                    >{{ pctText(c.percent) }}</span>
                    <span
                      v-else-if="i > 0 && c.incompatible"
                      class="ml-1 text-xs text-slate-400 dark:text-slate-500"
                      :title="c.incompatible"
                    >несравнимо</span>
                  </template>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
    </div>
  </div>
</template>
