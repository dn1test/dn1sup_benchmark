<script setup>
import { computed, onMounted } from 'vue'
import { Moon, Sun } from 'lucide-vue-next'
import { bootstrap, state } from './bridge'
import { useTheme } from './useTheme'
import SystemPanel from './components/SystemPanel.vue'
import RunPanel from './components/RunPanel.vue'
import TestsPanel from './components/TestsPanel.vue'
import ResultsPanel from './components/ResultsPanel.vue'
import ComparePanel from './components/ComparePanel.vue'

const { isDark, toggleTheme } = useTheme()

onMounted(bootstrap)

const version = computed(() => {
  const meta = state.overview && state.overview.environment
  return meta && meta.benchmark_version ? 'v' + meta.benchmark_version : ''
})

const noticeCls = computed(() => ({
  info: 'bg-brand-50 text-brand-800 dark:bg-brand-900/40 dark:text-brand-200',
  ok: 'bg-emerald-50 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-200',
  err: 'bg-red-50 text-red-700 dark:bg-red-950/60 dark:text-red-300'
}[state.notice ? state.notice.kind : 'info']))
</script>

<template>
  <div class="flex h-screen flex-col p-2.5">
    <div class="mb-2 flex items-center gap-2">
      <span class="text-base font-semibold">DN1Sup Benchmark</span>
      <span class="text-xs text-slate-400 dark:text-slate-500">{{ version }}</span>
      <span
        v-if="state.running"
        class="animate-pulse rounded-full bg-brand-100 px-2 py-0.5 text-[11px] font-medium text-brand-700 dark:bg-brand-900/60 dark:text-brand-300"
      >прогон идёт</span>
      <button
        class="ss-btn-ghost ml-auto !px-2"
        title="Светлая/тёмная тема"
        @click="toggleTheme"
      >
        <Sun v-if="isDark" :size="15" />
        <Moon v-else :size="15" />
      </button>
    </div>

    <div
      v-if="state.notice"
      class="mb-2 rounded-lg px-3 py-2 text-xs leading-5"
      :class="noticeCls"
    >{{ state.notice.text }}</div>

    <!-- Одна страница: слева система + запуск с логом, справа страница тестов -->
    <div class="flex min-h-0 flex-1 gap-2">
      <div class="flex w-[340px] shrink-0 flex-col gap-2">
        <SystemPanel />
        <RunPanel class="min-h-0 flex-1" />
      </div>
      <div class="ss-card min-w-0 flex-1 overflow-y-auto p-3">
        <h2 class="ss-label mb-2">Тесты</h2>
        <TestsPanel />
        <hr class="my-3 border-slate-200 dark:border-slate-800">
        <h2 class="ss-label mb-2">Результаты</h2>
        <ResultsPanel />
        <hr class="my-3 border-slate-200 dark:border-slate-800">
        <h2 class="ss-label mb-2">Сравнение</h2>
        <ComparePanel />
      </div>
    </div>
  </div>
</template>
