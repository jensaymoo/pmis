/**
 * Стор сессии и текущего пользователя.
 *
 * См. pmis.wiki/docs/frontend-spec.md §6, auth-and-navigation-api.md,
 * access-and-roles-business.md (token_version).
 */

import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import { getClient, getToken, setToken, clearToken, decodeJwtPayload } from '../lib/postgrest'

export const useAuthStore = defineStore('auth', () => {
  /**
   * Профиль текущего пользователя (форма ответа GET /rpc/me), либо null до входа.
   * @type {import('vue').Ref<{id: string, email: string, full_name: string, role: string, role_name: string, org_unit_id: string, start_route: string}|null>}
   */
  const user = ref(null)

  /**
   * Реактивная копия токена. `document.cookie` сама по себе не отслеживается
   * Vue-реактивностью: computed(), читающий getToken() напрямую, вычислился бы
   * один раз (при первом обращении, обычно token=null) и держал бы этот
   * результат вечно — у него нет ни одной реактивной зависимости, от которой
   * можно было бы инвалидировать кэш (подтверждено эмпирически: guard навечно
   * "залипал" на isAuthenticated=false после успешного логина). Поэтому токен
   * держим в обычном ref и обновляем его явно в login()/logout() — именно эти
   * присваивания и являются реактивным триггером для isAuthenticated.
   * @type {import('vue').Ref<string|null>}
   */
  const token = ref(getToken())

  /**
   * true, только если токен присутствует и не истёк (exp * 1000 > Date.now()).
   */
  const isAuthenticated = computed(() => {
    if (!token.value) return false
    const payload = decodeJwtPayload(token.value)
    if (!payload || !payload.exp) return false
    return payload.exp * 1000 > Date.now()
  })

  /**
   * Вход по email и паролю. При ошибке бросает Error с обобщённым текстом
   * (не раскрывает причину отказа сервера — 401 или 423 locked одинаковы для UI).
   * @param {string} email
   * @param {string} password
   * @returns {Promise<void>}
   */
  async function login(email, password) {
    const { data, error } = await getClient().rpc('login', { email, password })
    if (error) {
      throw new Error('Неверный email или пароль')
    }
    setToken(data.token)
    token.value = data.token
  }

  /**
   * Загружает профиль текущего пользователя.
   * @returns {Promise<object>}
   */
  async function fetchMe() {
    const { data, error } = await getClient().rpc('me')
    if (error) {
      throw new Error(error.message)
    }
    user.value = data
    return data
  }

  /**
   * Выход: серверный logout best-effort, локальная очистка — всегда.
   * @returns {Promise<void>}
   */
  async function logout() {
    try {
      await getClient().rpc('logout')
    } catch {
      // игнорируем сетевую ошибку — токен всё равно очищается локально
    }
    clearToken()
    token.value = null
    user.value = null
    const { useMenuStore } = await import('./menu')
    useMenuStore().reset()
  }

  /**
   * Смена пароля текущего пользователя. При успехе сервер инкрементирует
   * token_version, отчего текущий токен становится невалидным — вызывающий
   * UI-код обязан сам вызвать logout()/редирект после успеха.
   * @param {string} oldPassword
   * @param {string} newPassword
   * @returns {Promise<void>}
   */
  async function changePassword(oldPassword, newPassword) {
    const { error } = await getClient().rpc('change_password', {
      old_password: oldPassword,
      new_password: newPassword,
    })
    if (error) {
      throw new Error(error.message)
    }
  }

  return {
    user,
    isAuthenticated,
    login,
    fetchMe,
    logout,
    changePassword,
  }
})
