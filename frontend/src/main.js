import { createApp } from 'vue'
import { createPinia } from 'pinia'
import naive from 'naive-ui'
import App from './App.vue'
import router from './router'
import { setUnauthorizedHandler } from './lib/postgrest'
import { useAuthStore } from './stores/auth'
import './assets/main.css'

const app = createApp(App)
const pinia = createPinia()

app.use(naive)
app.use(pinia)
app.use(router)

/**
 * Сквозной перехват 401: любой запрос через getClient(), получивший 401,
 * вызывает этот обработчик — сессия завершается и пользователь
 * перенаправляется на /login с сохранением текущего маршрута
 * (frontend-spec.md §6, auth-and-navigation-main-layout.md §5.4).
 */
setUnauthorizedHandler(() => {
  const auth = useAuthStore(pinia)
  auth.logout()
  router.push({ path: '/login', query: { redirect: router.currentRoute.value.fullPath } })
})

app.mount('#app')
