<script setup>
import { computed } from 'vue'
import { FolderOpen, RefreshCw } from 'lucide-vue-next'
import { state, refreshOverview, openReports } from '../bridge'

const meta = computed(() => (state.overview && state.overview.environment) || {})
const env = computed(() => meta.value.environment || {})
const vp = computed(() => env.value.viewport || {})

const envRows = computed(() => [
  ['SketchUp', (meta.value.sketchup_version || '?') + ' (' + (meta.value.version_number || '') + ')'],
  ['Ruby', meta.value.ruby_version],
  ['ОС / платформа', (meta.value.os || '') + ' / ' + (meta.value.platform || '')],
  ['CPU', (meta.value.cpu || '?') + ' × ' + (meta.value.cores || '?')],
  ['Масштаб DPI', env.value.ui_scale_factor],
  ['Вьюпорт', vp.value.width ? vp.value.width + '×' + vp.value.height : null]
])
</script>

<template>
  <div class="ss-card shrink-0 p-3">
    <h3 class="ss-label mb-2">Параметры системы</h3>
    <table class="bench-table">
      <tbody>
        <tr v-for="row in envRows" :key="row[0]">
          <th class="w-28 align-top">{{ row[0] }}</th>
          <td class="whitespace-normal break-words">{{ row[1] === null || row[1] === undefined ? '—' : row[1] }}</td>
        </tr>
      </tbody>
    </table>
    <div class="mt-2 flex gap-2">
      <button class="ss-btn-ghost !py-1 text-xs" @click="openReports">
        <FolderOpen :size="14" /> Папка отчётов
      </button>
      <button class="ss-btn-ghost !py-1 text-xs" @click="refreshOverview">
        <RefreshCw :size="14" /> Обновить
      </button>
    </div>
    <div class="mt-1 text-[10px] leading-4 text-slate-400 dark:text-slate-500">
      GPU-движок и счётчики CPU/GPU/VRAM через API недоступны — не измеряются (null), а не 0.
    </div>
  </div>
</template>
