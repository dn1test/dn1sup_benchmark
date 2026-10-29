import { ref, onMounted } from 'vue'

const isDark = ref(false)

// Домашний паттерн (dn1sup_save_settings / dn1sup_comp_add_view), ключ — свой
// у расширения, чтобы не конфликтовать с другими диалогами.
const THEME_KEY = 'dn1sup_benchmark_theme'

export function useTheme() {
  function applyTheme(dark) {
    isDark.value = dark
    document.documentElement.classList.toggle('dark', dark)
    try {
      localStorage.setItem(THEME_KEY, dark ? 'dark' : 'light')
    } catch {
      // localStorage может быть недоступен — не критично
    }
  }

  function toggleTheme() {
    applyTheme(!isDark.value)
  }

  onMounted(() => {
    try {
      const saved = localStorage.getItem(THEME_KEY)
      applyTheme(saved ? saved === 'dark' : false)
    } catch {
      applyTheme(false)
    }
  })

  return { isDark, toggleTheme, applyTheme }
}
