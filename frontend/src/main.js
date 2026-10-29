import { createApp } from 'vue'
import { isMock } from './bridge'
import { installMock } from './mocks'
import App from './App.vue'
import './style.css'

// Мост регистрируется при импорте bridge.js (до монтирования Vue), поэтому
// пуши Ruby, пришедшие раньше mount, уже не потеряются.
if (isMock) installMock()

createApp(App).mount('#app')
