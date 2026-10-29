<script setup>
import { computed } from 'vue'

const props = defineProps({ status: { type: String, default: '' } })

const cls = computed(() => ({
  passed: 'bg-teal-100 text-teal-800 dark:bg-teal-900/50 dark:text-teal-300',
  failed: 'bg-orange-100 text-orange-800 dark:bg-orange-900/50 dark:text-orange-300',
  cancelled: 'bg-slate-200 text-slate-600 dark:bg-slate-700 dark:text-slate-300',
  skipped: 'bg-slate-200 text-slate-600 dark:bg-slate-700 dark:text-slate-300'
}[props.status] || 'bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300'))
</script>

<template>
  <span
    class="inline-block rounded-full px-2 py-0.5 text-[11px] font-medium leading-4"
    :class="cls"
  >{{ status }}</span>
</template>
