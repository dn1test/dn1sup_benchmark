// Копирует собранный самодостаточный index.html в папку html расширения.
// Отдельный шаг нужен, потому что запись vite напрямую в сетевой путь
// U:\...\ui\html нестабильна (файл остаётся старым), а явный
// fs.copyFileSync поверх существующего файла — надёжный.
import { copyFileSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const src = resolve(here, '../dist/index.html')
const dst = resolve(here, '../../dn1sup_benchmark/ui/html/index.html')

copyFileSync(src, dst)
const kb = (statSync(dst).size / 1024).toFixed(1)
console.log(`deploy: ${src} -> ${dst} (${kb} kB)`)
