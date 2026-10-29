<script setup>
import { computed, nextTick, ref, watch } from 'vue'
import { Play, X } from 'lucide-vue-next'
import { state, startRun, cancelRun } from '../bridge'

const logEl = ref(null)

const loadSummary = computed(() => {
  const p = state.plan
  if (!p) return ''
  return 'Набор v' + (state.overview && state.overview.environment
    ? state.overview.environment.test_suite_version : '?') + ': ' +
    (p.steps ? p.steps.length : 0) + ' шагов, файл ~' +
    ((p.params && p.params.target_mb) || '?') + ' МБ, полный прогон ~1 минута.'
})

const logLineCls = {
  info: 'text-slate-500 dark:text-slate-400',
  ok: 'text-emerald-600 dark:text-emerald-400',
  err: 'text-red-500 dark:text-red-400',
  done: 'text-brand-600 dark:text-brand-400'
}

// Автоскролл лога, как в исходном appendLog
watch(() => state.runLog.length, async () => {
  await nextTick()
  if (logEl.value) logEl.value.scrollTop = logEl.value.scrollHeight
})
</script>

<template>
  <div class="ss-card flex flex-col p-3">
    <h3 class="ss-label mb-2">Запуск теста</h3>

    <!-- Старт -->
    <div v-if="!state.running" class="shrink-0">
      <div class="rounded-lg bg-slate-200/60 px-2.5 py-1.5 text-[11px] leading-4 text-slate-600 dark:bg-slate-800/60 dark:text-slate-300">
        <b>Временно создаёт и откатывает</b> геометрию в текущей модели: сохраните модель
        и не переключайте вкладки до конца прогона. Тест файла (~130 МБ) собирает файл во
        временную папку, открывает и удаляет; UI на время кратко блокируется.
        <div class="mt-1">{{ loadSummary }}</div>
      </div>
      <button class="ss-btn-primary mt-2" @click="startRun">
        <Play :size="14" /> Запустить
      </button>
    </div>

    <!-- Прогресс -->
    <div v-else class="shrink-0">
      <div class="flex items-center gap-2">
        <div class="h-4 flex-1 overflow-hidden rounded-full bg-slate-200 dark:bg-slate-800">
          <div
            class="h-full rounded-full bg-brand-500 transition-[width] duration-300"
            :style="{ width: state.runBarPct + '%' }"
          ></div>
        </div>
        <span class="mono text-xs">{{ state.runCounter }}</span>
        <button class="ss-btn-danger !py-1 text-xs" @click="cancelRun">
          <X :size="14" /> Отменить
        </button>
      </div>
      <div class="mt-2 text-xs">{{ state.runCurrent }}</div>
    </div>

    <!-- Лог -->
    <h3 class="ss-label mb-1 mt-2 shrink-0">Лог тестов</h3>
    <div
      ref="logEl"
      class="mono min-h-12 flex-1 overflow-y-auto rounded-lg border border-slate-200 bg-white p-2 leading-5 dark:border-slate-800 dark:bg-slate-900/60"
    >
      <div v-if="!state.runLog.length" class="text-slate-400 dark:text-slate-500">— пусто —</div>
      <div v-for="(l, i) in state.runLog" :key="i" :class="logLineCls[l.kind] || ''">{{ l.text }}</div>
    </div>
  </div>
</template>
