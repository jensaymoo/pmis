import { createRouter, createWebHistory } from 'vue-router'
import MainLayout from '../layouts/MainLayout.vue'
import LoginPage from '../pages/LoginPage.vue'
import GanttPage from '../pages/GanttPage.vue'
import WorkOrdersPage from '../pages/WorkOrdersPage.vue'
import WorksPage from '../pages/WorksPage.vue'
import UsersPage from '../pages/UsersPage.vue'
import ResourcesPage from '../pages/ResourcesPage.vue'
import QuantityUnitsPage from '../pages/QuantityUnitsPage.vue'
import { useAuthStore } from '../stores/auth'
import { useMenuStore } from '../stores/menu'

/**
 * Статический список маршрутов приложения (Фаза 3 — каркас фронтенда).
 * Набор маршрутов фиксирован в коде (frontend-spec.md §3): БД в будущем будет
 * хранить лишь пути экранов для построения меню и стартового редиректа, но не
 * для генерации самих роутов.
 *
 * `/login` — отдельный top-level маршрут вне каркаса (frontend-spec.md §7).
 * Остальные экраны — вложенные маршруты под `MainLayout` (единый каркас).
 *
 * Маршрут `/` не имеет статического redirect — стартовый экран роли решает
 * navigation guard ниже (динамически, из auth.user.start_route).
 */
const routes = [
  {
    path: '/login',
    name: 'login',
    component: LoginPage,
  },
  {
    path: '/',
    component: MainLayout,
    children: [
      {
        path: 'gantt',
        name: 'gantt',
        component: GanttPage,
      },
      {
        path: 'work-orders',
        name: 'work-orders',
        component: WorkOrdersPage,
      },
      {
        path: 'works',
        name: 'works',
        component: WorksPage,
      },
      {
        path: 'users',
        name: 'users',
        component: UsersPage,
      },
      {
        path: 'resources/:kind',
        name: 'resources',
        component: ResourcesPage,
      },
      {
        path: 'quantity-units',
        name: 'quantity-units',
        component: QuantityUnitsPage,
      },
    ],
  },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

/**
 * Глобальный navigation guard (frontend-spec.md §6, auth-and-navigation-login.md §4.3,
 * auth-and-navigation-main-layout.md §5).
 *
 * Правила:
 * - `/login` с активной сессией → мгновенный редирект на стартовый экран роли
 *   (форма входа не должна "мигнуть" перед редиректом).
 * - Любой другой маршрут без активной сессии → редирект на `/login` с
 *   сохранением целевой ссылки в query.redirect.
 * - Активная сессия, но профиль/меню ещё не загружены (например, после
 *   обновления страницы с валидной cookie) → подгружаются здесь, до рендера.
 * - `/` → редирект на стартовый экран роли.
 * - Маршрут, отсутствующий в меню текущей роли → редирект на `/login`
 *   (guard не обрабатывает ошибки навигации самостоятельно иначе).
 *
 * useAuthStore()/useMenuStore() вызываются внутри колбэка (не на верхнем
 * уровне модуля), т.к. Pinia устанавливается в main.js до первой навигации,
 * но не обязательно до импорта этого модуля.
 */
router.beforeEach(async (to) => {
  const auth = useAuthStore()
  const menu = useMenuStore()

  if (to.path === '/login') {
    if (!auth.isAuthenticated) {
      return true
    }
    if (!auth.user) {
      try {
        await auth.fetchMe()
      } catch {
        await auth.logout()
        return true
      }
    }
    if (!menu.loaded) {
      await menu.load()
    }
    return auth.user?.start_route || '/'
  }

  if (!auth.isAuthenticated) {
    return { path: '/login', query: { redirect: to.fullPath } }
  }

  if (!auth.user) {
    try {
      await auth.fetchMe()
    } catch {
      await auth.logout()
      return { path: '/login', query: { redirect: to.fullPath } }
    }
  }

  if (!menu.loaded) {
    await menu.load()
  }

  if (to.path === '/') {
    return auth.user.start_route
  }

  if (!menu.hasRoute(to.path)) {
    return '/login'
  }

  return true
})

export default router
