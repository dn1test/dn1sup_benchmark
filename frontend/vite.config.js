import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

// Собираем самодостаточный index.html (JS и CSS инлайном) в dist/, а скрипт
// deploy (внутри npm run build) копирует его в папку html расширения — именно
// её открывает UI::HtmlDialog (dialog.rb, set_file). Отдельный шаг доставки
// надёжнее прямой записи vite в сетевой U:-путь.
export default defineConfig({
  plugins: [vue(), tailwindcss(), viteSingleFile()],
  build: {
    outDir: 'dist',
    target: 'es2020'
  }
})
