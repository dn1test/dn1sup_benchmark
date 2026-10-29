/* Форматирование значений бенчмарка (порт helpers из ui/html/app.js). */

export function fmt(v, unit) {
  if (v === null || v === undefined) return '—'
  if (unit === 'fps') return Number(v).toFixed(1) + ' fps'
  const n = Number(v)
  return n >= 1000 ? (n / 1000).toFixed(2) + ' с' : n.toFixed(1) + ' мс'
}

/* Порог значимости ±3%: внутри — нейтрально, вне — зелёный/красный.
 * higher — «больше = лучше» (для fps); для общего балла true. */
export function pctClass(percent, higher = true) {
  if (percent === undefined || percent === null) return 'text-slate-400 dark:text-slate-500'
  if (Math.abs(percent) < 3) return 'text-slate-400 dark:text-slate-500'
  const good = higher ? percent > 0 : percent < 0
  return good ? 'text-emerald-600 dark:text-emerald-400' : 'text-red-500 dark:text-red-400'
}

export function pctText(percent) {
  return (percent >= 0 ? '+' : '') + percent + '%'
}
