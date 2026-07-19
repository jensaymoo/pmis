# PMIS — Project Management Information System

Система управления проектами для внутреннего использования. Архитектура строится на PostgreSQL с REST-слоем PostgREST — без кастомного бэкенда. Бизнес-логика, авторизация и контракт API живут внутри СУБД.

---

## Содержание

- [Стек](#стек)
- [Быстрый старт](#быстрый-старт)
- [Документация](#документация)
  - [Бизнес-контекст](#бизнес-контекст)
  - [Реализация](#реализация)
  - [API-контракт](#api-контракт)
  - [Экраны](#экраны)
- [Роадмап](#роадмап)
- [Безопасность](#безопасность)
- [Структура каталогов](#структура-каталогов)

---

## Стек

| Слой | Технология |
|---|---|
| Язык | JavaScript, без TypeScript (JSDoc) |
| Фреймворк | Vue 3.5+ (Composition API, `<script setup>`) |
| Модули | ES-модули; composables |
| Стейт | Pinia 3 |
| Роутер | Vue Router 5 |
| Сборка | Vite 8 + @vitejs/plugin-vue 6 |
| HTTP к БД | @supabase/postgrest-js 2 (`PostgrestClient`) |
| UI-оболочка | Naive UI 2.41+ (лэйаут, формы, меню, нотификации) |
| Таблицы/гриды | Naive UI (`n-data-table`) |
| Диаграмма Ганта | Bryntum Gantt (лицензия требуется) |
| Карты | vue3-openlayers 12.2.2 (подложка OpenStreetMap) |
| CSS-утилиты | Tailwind CSS 4 |
| Backend | PostgREST 14+ (REST поверх PostgreSQL) |
| БД | PostgreSQL 17+ с расширением pgjwt |
| Auth/Authz | pgcrypto (bcrypt) + pgjwt, RLS, Postgres roles |

**Стратегия подключения UI-библиотек:**

- **Naive UI** — регистрируется **глобально**: корневые провайдеры (тема, локаль, уведомления, индикатор загрузки) и компоненты доступны во всех шаблонах без локального импорта.
- **Tailwind CSS** — подключается **глобально**: единая директива импорта в глобальном CSS; утилитарные классы доступны в любом шаблоне.

---

## Быстрый старт

```bash
cd frontend
npm install
npm run dev      # dev-сервер (Vite, :5173)
npm run build    # production build
npm run lint     # ESLint
```

Команды применимы после создания каталога `frontend/`. На текущий момент этого каталога ещё нет: проект находится на стадии документации и схемы данных, поэтому `npm install` и `npm run dev` запустятся только на этапе «Каркас фронтенда» ( roadmap/03-frontend-skeleton.md).

---

## Документация

Вся документация переехала в **GitHub Wiki** — каталог `pmis.wiki/`. Структура плоская: файлы лежат в `pmis.wiki/docs/*.md` с префиксами по слою (`*-business`, `backend-*`, `*-api`, `*-screen` / UI). Точки входа — [`pmis.wiki/Home.md`](pmis.wiki/Home.md) и [`pmis.wiki/_Sidebar.md`](pmis.wiki/_Sidebar.md). Ссылки ниже даны в wiki-стиле (без расширения), файлы физически находятся в `pmis.wiki/docs/`.

Документация каждого домена разбита на слои: **Бизнес-логика** (что и почему, без деталей реализации), **Бэкенд** (таблицы, RLS, миграции, RPC), **API** (REST-контракт), **UI/UX** (экраны). Глоссарий и обзор — в [`Home`](pmis.wiki/docs/../Home.md).

### Технические спецификации

| Документ | Содержание |
|---|---|
| [frontend-spec](pmis.wiki/docs/frontend-spec.md) | ТЗ и архитектура фронтенда, лэйаут, тема |
| [backend-spec](pmis.wiki/docs/backend-spec.md) | Обзор БД, стек, архитектура, индекс бэкенд-документов |
| [audit-spec](pmis.wiki/docs/audit-spec.md) | Поля `created_*`/`updated_*`, триггер из JWT-claim, UTC |
| [navigation-spec](pmis.wiki/docs/navigation-spec.md) | Screen/menu_item, роуты, guards |

### Структура работ

| Слой | Документ |
|---|---|
| Бизнес-логика | [work-structure-business](pmis.wiki/docs/work-structure-business.md) |
| Бэкенд | [backend-work-structure](pmis.wiki/docs/backend-work-structure.md) |
| API | [work-structure-api](pmis.wiki/docs/work-structure-api.md) |

### Планирование

| Слой | Документ |
|---|---|
| Бизнес-логика | [planning-business](pmis.wiki/docs/planning-business.md), [daily-plan-business](pmis.wiki/docs/daily-plan-business.md) |
| Бэкенд | [backend-planning](pmis.wiki/docs/backend-planning.md) |
| API | [planning-api](pmis.wiki/docs/planning-api.md) |
| UI/UX | [planning-gantt](pmis.wiki/docs/planning-gantt.md) |

### Участки

| Слой | Документ |
|---|---|
| Бизнес-логика | [sections-business](pmis.wiki/docs/sections-business.md) |
| Бэкенд | [backend-sections](pmis.wiki/docs/backend-sections.md) |
| API | [sections-api](pmis.wiki/docs/sections-api.md) |
| UI/UX | [sections-screen](pmis.wiki/docs/sections-screen.md) |

### Ресурсы

| Слой | Документ |
|---|---|
| Бизнес-логика | [resources-business](pmis.wiki/docs/resources-business.md) |
| Бэкенд | [backend-resources](pmis.wiki/docs/backend-resources.md) |
| API | [resources-api](pmis.wiki/docs/resources-api.md) |
| UI/UX | [resources-pattern](pmis.wiki/docs/resources-pattern.md) |

### Факт и наряды

| Слой | Документ |
|---|---|
| Бизнес-логика | [fact-and-work-orders-business](pmis.wiki/docs/fact-and-work-orders-business.md) |
| Бэкенд | [backend-fact-and-work-orders](pmis.wiki/docs/backend-fact-and-work-orders.md) |
| API | [fact-and-work-orders-api](pmis.wiki/docs/fact-and-work-orders-api.md) |

### Аутентификация и навигация

| Слой | Документ |
|---|---|
| Бизнес-логика | [auth-and-navigation-business](pmis.wiki/docs/auth-and-navigation-business.md) |
| Бэкенд | [backend-auth-and-navigation](pmis.wiki/docs/backend-auth-and-navigation.md) |
| API | [auth-and-navigation-api](pmis.wiki/docs/auth-and-navigation-api.md) |
| UI/UX | [auth-and-navigation-login](pmis.wiki/docs/auth-and-navigation-login.md), [auth-and-navigation-main-layout](pmis.wiki/docs/auth-and-navigation-main-layout.md) |

### Доступ и роли

| Слой | Документ |
|---|---|
| Бизнес-логика | [access-and-roles-business](pmis.wiki/docs/access-and-roles-business.md) |
| Бэкенд | [backend-access-and-roles](pmis.wiki/docs/backend-access-and-roles.md) |
| API | [access-and-roles-api](pmis.wiki/docs/access-and-roles-api.md) |
| UI/UX | [access-and-roles-users](pmis.wiki/docs/access-and-roles-users.md) |

**Правило чистоты:** бизнес-файлы (`*-business`) не содержат имён таблиц, колонок, миграций, функций, триггеров, фреймворков, маршрутов, HTTP-кодов. Правила формулируются в доменных терминах.

**Общее:**
- **Базовый URL**: `http://localhost:3000` (PostgREST)
- **Аутентификация**: JWT-токен в заголовке `Authorization: Bearer <token>`
- **Ошибки**: `{ "code": "PGRSTxxx", "message": "..." }`
- **DELETE**: возвращает 204 No Content; для получения удалённой записи — `Prefer: return=representation`
- **Мягкое удаление**: `DELETE` переводит запись в `status = 'deprecated'`
- **RPC**: функции, возвращающие `void`, отдают 204; функции, возвращающие `json`, отдают 200 с телом.
- **Seed-only ресурсы** не управляются через REST: `screen`, `roles`, `menu_item`, ENUM-типы.
- **Аудит-поля**: ответы доменных сущностей содержат `created_at`/`created_by`/`updated_at`/`updated_by` согласно [audit-spec.md](pmis.wiki/docs/audit-spec.md). Клиент их не передаёт. Исключения из `record_status` (но с аудит-полями): `work_order`, `work_order_task`, `task_daily_plan`, `work_order_task_fact`, `*_resource_fact`.
- **Исключения из мягкого удаления**: `work_order` (через `POST /rpc/cancel_work_order`), `work_order_task` (строки сохраняются при cancel наряда), `task_daily_plan` (физическое удаление), `*_resource_fact` и `work_order_task_fact` (через `close_work_order`).

---

### Экраны

`pmis.wiki/docs/*-screen`, `pmis.wiki/docs/auth-and-navigation-*`, `pmis.wiki/docs/resources-*`, `pmis.wiki/docs/access-and-roles-users.md` описывают реализацию каждого экрана и справочного паттерна.

| Экран | Маршрут | Роль | Документ |
|---|---|---|---|
| Вход | `/login` | анонимный | [login](pmis.wiki/docs/auth-and-navigation-login.md) |
| Основной лэйаут | `/` | все аутентифицированные | [main-layout](pmis.wiki/docs/auth-and-navigation-main-layout.md) |
| Гант | `/gantt` | `planner`, `admin` | [planning](pmis.wiki/docs/planning-gantt.md) |
| Справочники (паттерн) | — | по справочнику | [references](pmis.wiki/docs/resources-pattern.md) |
| Пользователи | `/users` | `admin` | [users](pmis.wiki/docs/access-and-roles-users.md) |
| Персонал (справочник) | `/resources/personnel` | `planner`, `admin` | [personnel](pmis.wiki/docs/resources-personnel.md) |
| Техника (справочник) | `/resources/equipment` | `planner`, `admin` | [equipment](pmis.wiki/docs/resources-equipment.md) |
| Материалы (справочник) | `/resources/materials` | `planner`, `admin` | [materials](pmis.wiki/docs/resources-materials.md) |
| Единицы объёма | `/quantity-units` | `planner`, `admin` | [qty-unit](pmis.wiki/docs/planning-qty-unit.md) |
| Участки (экран) | — | `planner`, `admin` | [sections](pmis.wiki/docs/sections-screen.md) |
| Работы | `/works` | планируется | документ не готов (см. roadmap/08-works.md) |
| Наряды | `/work-orders` | планируется | документ не готов (см. roadmap/07-work-orders.md) |
| Участки | `/sections` | `planner`, `admin`, `dispatcher` | справочник (модалка `SectionsGrid`, фаза 5) |

**Подфайлы Ганта:** [task-editor](pmis.wiki/docs/planning-task-editor.md) · [task-sections](pmis.wiki/docs/planning-task-sections.md) · [task-resources](pmis.wiki/docs/planning-task-resources.md) · [dependencies](pmis.wiki/docs/planning-dependencies.md) · [qty-unit](pmis.wiki/docs/planning-qty-unit.md)

**Подфайлы ресурсов (паттерн):** [personnel](pmis.wiki/docs/resources-personnel.md) · [personnel-groups](pmis.wiki/docs/resources-personnel-groups.md) · [personnel-units](pmis.wiki/docs/resources-personnel-units.md) · [equipment](pmis.wiki/docs/resources-equipment.md) · [equipment-groups](pmis.wiki/docs/resources-equipment-groups.md) · [equipment-units](pmis.wiki/docs/resources-equipment-units.md) · [materials](pmis.wiki/docs/resources-materials.md) · [materials-groups](pmis.wiki/docs/resources-materials-groups.md) · [materials-units](pmis.wiki/docs/resources-materials-units.md) · [qty-unit](pmis.wiki/docs/planning-qty-unit.md)

---

## Роадмап

Полный план реализации — 9 фаз в `roadmap/`.

| Фаза | Файл | Оценка |
|---|---|---|
| 1. Инфраструктура | [01-infrastructure.md](roadmap/01-infrastructure.md) | 2–3 дня |
| 2. Схема данных | [02-data-schema.md](roadmap/02-data-schema.md) | 14–18 дней |
| 3. Каркас фронтенда | [03-frontend-skeleton.md](roadmap/03-frontend-skeleton.md) | 2–3 дня |
| 4. Авторизация | [04-auth.md](roadmap/04-auth.md) | 5–6 дней |
| 5. Справочники | [05-references.md](roadmap/05-references.md) | 10–13 дней |
| 6. Планирование (Гант) | [06-gantt.md](roadmap/06-gantt.md) | 10–14 дней |
| 7. Наряды и факт | [07-work-orders.md](roadmap/07-work-orders.md) | 8–10 дней |
| 8. Работы (read-only) | [08-works.md](roadmap/08-works.md) | 3–4 дня |
| 9. Финализация | [09-finalization.md](roadmap/09-finalization.md) | 4–6 дней |
| **Итого** | | **58–77 дней** |

---

## Безопасность

- JWT хранится в cookie (`SameSite=Strict`, `Path=/`). Предпочтительно: **httpOnly** через reverse-proxy (nginx читает cookie, подставляет `Authorization: Bearer`).
- Секрет JWT — database-level GUC `app.jwt_secret`, значение из `.env` (не в коде).
- Логаут = удаление cookie + `router.push('/login')`.

---

## Структура каталогов

> Узлы без пометки уже существуют в репозитории. Пометка «(планируется)» или «(планируется, фаза N)» означает, что файл или каталог ещё не создан и появится в ходе реализации фазы N.

```
/
├─ CLAUDE.MD
├─ pmis.wiki/                       # GitHub Wiki (вся документация)
│  ├─ Home.md                       # точка входа (обзор + глоссарий)
│  ├─ _Sidebar.md                   # навигация wiki
│  ├─ CLAUDE.md                     # дубликат Home.md + глоссарий
│  └─ docs/                         # плоская структура, префиксы по слою
│     ├─ frontend-spec.md
│     ├─ backend-spec.md
│     ├─ audit-spec.md
│     ├─ navigation-spec.md
│     ├─ work-structure-business.md
│     ├─ work-structure-api.md
│     ├─ backend-work-structure.md
│     ├─ planning-business.md
│     ├─ daily-plan-business.md
│     ├─ planning-api.md
│     ├─ backend-planning.md
│     ├─ planning-gantt.md
│     ├─ planning-task-editor.md
│     ├─ planning-task-sections.md
│     ├─ planning-task-resources.md
│     ├─ planning-dependencies.md
│     ├─ planning-qty-unit.md
│     ├─ sections-business.md
│     ├─ sections-api.md
│     ├─ backend-sections.md
│     ├─ sections-screen.md
│     ├─ resources-business.md
│     ├─ resources-api.md
│     ├─ backend-resources.md
│     ├─ resources-pattern.md
│     ├─ resources-personnel.md
│     ├─ resources-personnel-groups.md
│     ├─ resources-personnel-units.md
│     ├─ resources-equipment.md
│     ├─ resources-equipment-groups.md
│     ├─ resources-equipment-units.md
│     ├─ resources-materials.md
│     ├─ resources-materials-groups.md
│     ├─ resources-materials-units.md
│     ├─ fact-and-work-orders-business.md
│     ├─ fact-and-work-orders-api.md
│     ├─ backend-fact-and-work-orders.md
│     ├─ auth-and-navigation-business.md
│     ├─ auth-and-navigation-api.md
│     ├─ backend-auth-and-navigation.md
│     ├─ auth-and-navigation-login.md
│     ├─ auth-and-navigation-main-layout.md
│     ├─ access-and-roles-business.md
│     ├─ access-and-roles-api.md
│     ├─ backend-access-and-roles.md
│     └─ access-and-roles-users.md
├─ db/ (планируется, фаза 1)
│  ├─ Dockerfile
│  ├─ schema.dbml
│  └─ migrations/
├─ nginx/ (планируется, фаза 9)
│  └─ nginx.conf
├─ .env.example (планируется)
├─ docker-compose.yml (планируется)
├─ frontend/ (планируется)
│  ├─ index.html
│  ├─ vite.config.js
│  ├─ package.json
│  └─ src/
│     ├─ main.js
│     ├─ App.vue
│     ├─ assets/ (планируется, фаза 3)
│     │  ├─ logo.svg
│     │  ├─ main.css
│     │  └─ bryntum.css
│     ├─ lib/postgrest.js
│     ├─ stores/
│     │  ├─ auth.js
│     │  └─ menu.js
│     ├─ router/index.js
│     ├─ layouts/
│     │  └─ MainLayout.vue
│     ├─ components/
│     │  ├─ DynamicMenu.vue
│     │  ├─ gantt/GanttView.vue
│     │  ├─ grid/WorksGrid.vue
│     │  ├─ orders/WorkOrdersGrid.vue
│     │  ├─ orders/WorkOrderForm.vue
│     │  ├─ orders/WorkOrderResourceFact.vue
│     │  ├─ resources/ResourcesGrid.vue
│     │  ├─ resources/ResourceFormModal.vue
│     │  ├─ resources/UnitsTableModal.vue
│     │  ├─ resources/GroupsTableModal.vue
│     │  └─ admin/
│     │     ├─ OrgUnitTree.vue
│     │     └─ UsersGrid.vue
│     ├─ pages/
│     │  ├─ LoginPage.vue
│     │  ├─ GanttPage.vue
│     │  ├─ WorksPage.vue
│     │  ├─ WorkOrdersPage.vue
│     │  ├─ UsersPage.vue
│     │  └─ ResourcesPage.vue
│     └─ adapters/
│        ├─ bryntumPostgrest.js
│        └─ naivePostgrest.js
└─ roadmap/
   ├─ 01-infrastructure.md
   ├─ 02-data-schema.md
   ├─ 03-frontend-skeleton.md
   ├─ 04-auth.md
   ├─ 05-references.md
   ├─ 06-gantt.md
   ├─ 07-work-orders.md
   ├─ 08-works.md
   └─ 09-finalization.md
```
