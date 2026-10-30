/* Форматирование значений бенчмарка (порт helpers из ui/html/app.js). */

export function fmt(v, unit) {
  if (v === null || v === undefined) return '—'
  if (unit === 'fps') return Number(v).toFixed(1) + ' fps'
  const n = Number(v)
  return n >= 1000 ? (n / 1000).toFixed(2) + ' с' : n.toFixed(1) + ' мс'
}
