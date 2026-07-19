/**
 * Слой доступа к данным: инициализация REST-клиента (PostgREST), работа с
 * JWT-токеном (хранение/чтение/очистка) и сквозной перехват ответов 401.
 *
 * См. pmis.wiki/docs/frontend-spec.md §4–6.
 */

import { PostgrestClient } from '@supabase/postgrest-js'

const TOKEN_COOKIE_NAME = 'pmis_token'

/**
 * Единственный зарегистрированный обработчик 401-ответов (см. setUnauthorizedHandler).
 * @type {(() => void)|null}
 */
let unauthorizedHandler = null

/**
 * Защита от повторного входа: пока обработчик 401 уже выполняется, повторные
 * срабатывания игнорируются. Без этого флага возможна рекурсия — обработчик
 * вызывает auth.logout(), которая сама делает rpc('logout') СО СТАРЫМ (тем же
 * протухшим) токеном, сервер снова отвечает 401, интерцептор снова видит
 * запрос с Authorization-заголовком и вызывает обработчик заново, и так по
 * кругу (подтверждено эмпирически: цепочка ?redirect=/login?redirect=/login…
 * растущая до исчерпания таймаута). 2 секунды с запасом перекрывают время
 * одного цикла logout()+redirect, не блокируя реакцию на отдельный, более
 * поздний и не связанный 401.
 * @type {boolean}
 */
let handlingUnauthorized = false

/**
 * Читает JWT-токен из cookie.
 *
 * ВРЕМЕННОЕ РЕШЕНИЕ (текущая фаза): согласно CLAUDE.md «Безопасность», в проде
 * токен должен храниться в httpOnly-cookie, читаемой reverse-proxy (nginx),
 * который сам подставляет заголовок Authorization — это задача Фазы 9
 * (nginx ещё не настроен). Пока cookie читается/пишется напрямую из JS через
 * document.cookie — осознанное упрощение для текущей фазы.
 *
 * @returns {string|null}
 */
export function getToken() {
  const match = document.cookie.match(
    new RegExp(`(?:^|; )${TOKEN_COOKIE_NAME}=([^;]*)`),
  )
  return match ? decodeURIComponent(match[1]) : null
}

/**
 * Записывает JWT-токен в cookie (SameSite=Strict, Path=/).
 *
 * ВРЕМЕННОЕ РЕШЕНИЕ: см. комментарий в getToken() — прямой доступ к
 * document.cookie вместо httpOnly-cookie через reverse-proxy (Фаза 9).
 *
 * @param {string} token
 * @returns {void}
 */
export function setToken(token) {
  document.cookie = `${TOKEN_COOKIE_NAME}=${encodeURIComponent(token)}; SameSite=Strict; Path=/`
}

/**
 * Удаляет cookie с JWT-токеном.
 * @returns {void}
 */
export function clearToken() {
  document.cookie = `${TOKEN_COOKIE_NAME}=; SameSite=Strict; Path=/; Max-Age=0`
}

/**
 * Регистрирует единственный колбэк, вызываемый при получении 401 от любого
 * запроса, выполненного через клиент из getClient().
 *
 * @param {() => void} fn
 * @returns {void}
 */
export function setUnauthorizedHandler(fn) {
  unauthorizedHandler = fn
}

/**
 * Кастомный fetch, передаваемый в PostgrestClient: сквозной перехват 401 —
 * при обнаружении вызывает зарегистрированный обработчик (side-effect,
 * response не модифицируется), затем всегда возвращает исходный response,
 * чтобы postgrest-js сам сформировал свой обычный объект { data, error }.
 *
 * Обработчик срабатывает, ТОЛЬКО если исходный запрос нёс заголовок
 * Authorization (т.е. клиент считал сессию действующей, а сервер её отклонил —
 * это и есть «инвалидация сессии во время работы», frontend-spec.md §6).
 * 401 на запросе БЕЗ токена (неудачная попытка входа через rpc('login'),
 * анонимный rpc('logout')) — ожидаемый, штатный ответ, а не сигнал
 * инвалидации: без этой проверки обработчик вызывал auth.logout(), которая
 * сама делает сетевой запрос через этот же клиент, тоже получает 401 (нет
 * токена) и рекурсивно вызывает обработчик снова — подтверждённая эмпирически
 * бесконечная рекурсия (растущая цепочка ?redirect=/login?redirect=/login…).
 *
 * @param {RequestInfo|URL} input
 * @param {RequestInit} [init]
 * @returns {Promise<Response>}
 */
async function fetchWithUnauthorizedInterceptor(input, init) {
  const hadAuthHeader = new Headers(init?.headers).has('Authorization')
  const response = await fetch(input, init)
  if (response.status === 401 && hadAuthHeader && unauthorizedHandler && !handlingUnauthorized) {
    handlingUnauthorized = true
    setTimeout(() => {
      handlingUnauthorized = false
    }, 2000)
    unauthorizedHandler()
  }
  return response
}

/**
 * Создаёт новый экземпляр PostgrestClient, сконфигурированный на
 * `${window.location.origin}/api` (в dev — прокси Vite на :3000, см.
 * frontend/vite.config.js). Если есть сохранённый токен — подставляет его в
 * заголовок Authorization. Новый клиент создаётся при каждом вызове (не
 * синглтон), чтобы исключить проблему протухшего заголовка при обновлении
 * токена.
 *
 * @returns {PostgrestClient}
 */
export function getClient() {
  const token = getToken()
  /** @type {{ fetch: typeof fetch, headers?: Record<string, string> }} */
  const options = { fetch: fetchWithUnauthorizedInterceptor }
  if (token) {
    options.headers = { Authorization: `Bearer ${token}` }
  }
  return new PostgrestClient(`${window.location.origin}/api`, options)
}

/**
 * Парсит payload JWT (base64url, вторая часть между точками) и возвращает
 * объект claims (role, user_id, org_unit_id, token_version, exp). Не бросает
 * исключение наружу — при ошибке разбора возвращает null.
 *
 * @param {string} token
 * @returns {{role?: string, user_id?: string, org_unit_id?: string, token_version?: number, exp?: number}|null}
 */
export function decodeJwtPayload(token) {
  try {
    const parts = token.split('.')
    if (parts.length < 2) return null
    const base64url = parts[1]
    const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/')
    const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=')
    const json = decodeURIComponent(
      atob(padded)
        .split('')
        .map((c) => `%${c.charCodeAt(0).toString(16).padStart(2, '0')}`)
        .join(''),
    )
    return JSON.parse(json)
  } catch {
    return null
  }
}
