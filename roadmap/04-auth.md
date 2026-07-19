# Фаза 4 — Авторизация

> Логин, сессия, меню, гарды — полностью рабочие.

## Документы

| Документ | Что берём |
|----------|-----------|
| `pmis.wiki/docs/frontend-spec.md` §5–6 | postgrest.js, cookie, 401-перехватчик, сторы |
| `pmis.wiki/docs/navigation-spec.md` | Динамическое меню, guard, start_route |
| `pmis.wiki/docs/auth-and-navigation-login.md` | Форма входа, редирект, сессия |
| `pmis.wiki/docs/auth-and-navigation-business.md` | Логин, логаут, меню по роли, стартовый экран |

## Что делаем

- `lib/postgrest.js` — PostgrestClient, cookie-хелперы (get/set/clear token), автоматический `Authorization: Bearer`, глобальный 401-перехватчик (logout + redirect)
- `stores/auth.js` — `login()`, `fetchMe()`, `logout()`, `changePassword()`, `isAuthenticated`, reactive `user`
- `stores/menu.js` — `load()` (fetch menu_item + screen), `buildTree()`, `hasRoute()`
- `components/DynamicMenu.vue` — `n-menu` из `menu.tree`, подсветка активного маршрута
- `pages/LoginPage.vue` — форма email + пароль (Naive UI), вызов `auth.login()` → `fetchMe()` → `menu.load()` → redirect
- `components/auth/ChangePasswordModal.vue` — модалка: старый пароль + новый пароль → `POST /rpc/change_password`
- `layouts/MainLayout.vue` — `n-message-provider`, `n-notification-provider`, хедер (лого, меню, имя пользователя, кнопка выхода, кнопка смены пароля)
- `router/index.js` — `beforeEach` guard: нет токена → `/login?redirect=…`; есть токен на `/login` → start_route; маршрут не в `menu.hasRoute()` → redirect

## Готово когда

- Неаутентифицированный → `/login?redirect=/gantt`
- Логин планировщиком → меню (Гант, Работы, Ресурсы), redirect на `/gantt`
- Логин диспетчером → меню (Наряды, Работы, Ресурсы), redirect на `/work-orders`
- Логин админом → меню (Пользователи, подменю), redirect на `/users`
- Логин `disabled`-пользователем → ошибка «учётная запись деактивирована»
- Неверный пароль → уведомление, остаёмся на `/login`
- Логаут: `POST /rpc/logout` (инкремент token_version) → удаление cookie → `router.push('/login')` → сторы сброшены
- Протухший токен при запросе → авто-логаут по 401

**Оценка:** 5–6 дней
