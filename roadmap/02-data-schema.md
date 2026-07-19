# Фаза 2 — Схема данных (вся БД целиком)

> Сначала фиксируем всю модель данных в DBML, затем создаём миграции. После этой фазы PostgREST отдаёт данные и все API-эндпоинты доступны.

## Документы

| Документ | Что берём |
|----------|-----------|
| `pmis.wiki/docs/backend-spec.md` | Полная схема: все таблицы, триггеры, RLS, RPC, гранты, сид |
| `pmis.wiki/docs/audit-spec.md` | Триггер аудита, `record_status`, 4 поля |
| `pmis.wiki/docs/access-and-roles-business.md` | Роли, зоны, анти-эскалация, **жизненный цикл users** |
| `pmis.wiki/docs/work-structure-business.md` | WBS-дерево, рамки, лист/составная работа |
| `pmis.wiki/docs/planning-business.md` | Плановые поля, блокировка при наряде, пересчёт |
| `pmis.wiki/docs/sections-business.md` | Участки: area/linear, точки, привязки к работам |
| `pmis.wiki/docs/fact-and-work-orders-business.md` | Жизненный цикл наряда, close_work_order, роллап |
| `pmis.wiki/docs/resources-business.md` | 3 вида ресурсов, группы, план/факт, **блокировка деактивации членов группы**, **параллельные наряды на один ресурс** |
| `pmis.wiki/docs/navigation-spec.md` | screen, menu_item, roles, seed навигации |
| `pmis.wiki/docs/daily-plan-business.md` | Дневной план: правила распределения, остаток, привязка к факту, видимость для диспетчера |

## 2.0 — DBML-схема

> Перед написанием миграций описываем всю модель в `db/schema.dbml`. Это даёт наглядную карту таблиц, связей и типов, которую можно визуализировать (dbdiagram.io) и использовать как справочник при написании SQL.

- `db/schema.dbml` — полная схема всех таблиц, колонок, типов, FK, индексов, enum-ов
- Покрывает все домены: навигация, пользователи, WBS, участки, наряды, ресурсы (×3 вида)
- Включает ENUM-определения (`role_code`, `record_status`, `work_order_status`, `section_kind`, `task_type`, `dependency_type`, `screen_code`)
- Включает связи (Ref) между всеми таблицами
- Служит источником истины для структуры — миграции пишутся по нему (файл создаётся в рамках фазы 2, раздел 2.0)

**Готово когда:** `schema.dbml` описывает все ~31 таблицу из `backend-spec.md` (pmis.wiki/docs/backend-spec.md): 10 ядерных доменных + 18 ресурсных (×3 вида) + 3 служебные без аудита (`screen`, `menu_item`, `roles`); визуализация в dbdiagram.io отображает корректную ER-диаграмму.

## 2.1 — Фундамент

| Миграция | Содержание |
|----------|------------|
| `001_extensions` | pgcrypto, pgjwt |
| `002_enums` | `role_code`, `work_order_status`, `section_kind`, `record_status`, `task_type`, `dependency_type`, `screen_code` |
| `003_roles` | `authenticator`, `anon`, `admin`, `planner`, `dispatcher` |
| `004_helpers` | `current_user_id()`, `current_org_unit_id()`, `current_role()`, `org_subtree(uuid)` |
| `005_audit` | Триггер-функция `set_audit_fields()` |
| `006_jwt_secret` | GUC `app.jwt_secret` |

## 2.2 — Навигация и пользователи

| Миграция | Содержание |
|----------|------------|
| `010_screen` | Каталог экранов (без аудита) |
| `011_menu_item` | Меню: привязка к роли, вложенность, сортировка (без аудита) |
| `012_roles` | Роли + `start_screen_id` |
| `013_org_unit` | Оргструктура + аудит + RLS (org_subtree); **CRUD в рамках поддерева** |
| `014_users` | Пользователи + аудит + RLS + анти-эскалация + **record_status lifecycle** (деактивация блокируется при незакрытых нарядах/работах) + `token_version` (integer, NOT NULL DEFAULT 0, для инвалидации сессий при смене пароля) |

## 2.3 — RPC авторизации

| Миграция | Содержание |
|----------|------------|
| `015_login` | `login(email, password)` — bcrypt + JWT, SECURITY DEFINER, доступ `anon`; **только `enabled` пользователи**; поля `failed_attempts` (int, default 0) и `locked_until` (timestamptz, null) — триггер инкремента failed_attempts при неудачном входе; при 5+ попытках — locked_until = now() + 15min; проверка locked_until → 423 Locked; при успехе — сброс failed_attempts=0, locked_until=null |
| `016_me` | `me()` — профиль + start_route, доступ app-ролям |
| `017_nav_rls` | RLS на `menu_item` (фильтр по role_code из JWT) |
| `018_logout` | `logout()` — SECURITY DEFINER, доступ app-ролям; инкремент `token_version` текущего пользователя (инвалидация всех сессий) |
| `018a_change_password` | `change_password(old_password, new_password)` — bcrypt-проверка старого пароля, SECURITY DEFINER, доступ app-ролям; инкремент `token_version` (инвалидация прочих сессий), согласно `access-and-roles-business.md` / `backend-access-and-roles.md` |

> `issue_work_order`/`cancel_work_order` перенесены в раздел 2.6 (`042a`/`042b`) — физически
> зависят от таблицы `work_order`, которая появляется только там; нумерация `019`/`020` в этом
> разделе логически противоречила бы порядку создания объектов.

## 2.4 — Ядро: проекты, работы, единицы

| Миграция | Содержание |
|----------|------------|
| `021_qty_unit` | Единицы объёма (м, м², м³, шт, т, кг, компл, ч) + аудит + RLS |
| `022_project` | Проект + аудит + RLS |
| `023_task` | Работа (WBS-дерево, parent_id) + аудит + индексы. Доменные колонки: `org_unit_id`, `task_type` (leaf/composite/milestone), `start_date`, `end_date`, `plan_qty`, `qty_unit_id`, `percent_done`, `actual_start`, `actual_end`, `duration` |
| `024_task_rls` | RLS: планировщик CRUD плана; диспетчер/админ read-only |
| `025_task_triggers` | Рамки дат, пересчёт percent_done, блокировка при открытом наряде, роллап plan_qty |
| `026_task_dependency` | Зависимости сиблингов (`dependency_type` FS/SS/FF/SF + `lag`) + аудит + RLS; гарды: сиблинг, зона, проект, отсутствие циклов |

## 2.4.5 — Дневной план

| Миграция | Содержание |
|----------|------------|
| `027_task_daily_plan` | `task_daily_plan` + UNIQUE(task_id, task_section_id, date) + CHECK + триггер авто-создания/удаления дней; без `record_status`, с аудитом, гард удаления по факту |

## 2.5 — Участки

| Миграция | Содержание |
|----------|------------|
| `030_section` | Участок (area/linear) + аудит + RLS |
| `031_section_point` | Точки координат + CHECK (geographic → y NOT NULL) |
| `032_section_triggers` | Минимум точек: linear ≥ 2, area ≥ 3 |
| `033_task_section` | Привязка работа↔участок + UNIQUE + аудит + RLS |
| `034_task_section_triggers` | Работа = лист; та же org_subtree; роллап plan_qty |

## 2.6 — Наряды

| Миграция | Содержание |
|----------|------------|
| `040_work_order` | Наряд + аудит + RLS (диспетчер CRUD открытых; планировщик read-only) |
| `041_work_order_task` | Строка наряда — плановая привязка через `task_daily_plan_id` (не `task_id`+`plan_qty` напрямую: работа/участок/день и объём уже заданы дневным планом) + аудит + RLS |
| `041a_work_order_task_fact` | Факт-строка `work_order_task_fact`: SELECT read-only всем в зоне видимости; INSERT/UPDATE/DELETE запрещены через REST — заполняется только `close_work_order()` |
| `042_wo_task_triggers` | Работа = лист, plan_qty > 0, percent_done < 100, секция обязательна для секционированных |
| `042a_issue_work_order` | `issue_work_order(work_order_id)` — created→open, SECURITY DEFINER; проверка: работа = лист, org_unit совпадает с зоной диспетчера |
| `042b_cancel_work_order` | `cancel_work_order(work_order_id)` → canceled, SECURITY DEFINER; строки `work_order_task` остаются без изменений; `work_order_task_fact` не создаётся |
| `043_close_work_order_v1` | SECURITY DEFINER: суммирование факта, percent_done, actual_start/end, роллап по дереву |

## 2.7 — Ресурсы (×3 вида, 18 таблиц)

Паттерн повторяется для **personnel**, **equipment**, **materials**:

| Таблица | Назначение |
|---------|------------|
| `*_unit` | Единицы измерения ресурса (полное имя, сокращение, признак целочисленности) |
| `*_resource` | Конкретный ресурс |
| `*_group` | Группа ресурсов |
| `*_group_resource` | Привязка ресурс↔группа (M:N) |
| `*_resource_plan` | Плановое назначение на работу/участок |
| `*_resource_fact` | Фактическое использование (только через close_work_order); без `record_status`, с аудитом |

| Миграция | Содержание |
|----------|------------|
| `050–055` | personnel_* (6 таблиц + аудит + RLS + триггеры) |
| `056–061` | equipment_* |
| `062–067` | materials_* |
| `068` | VIEW для агрегации план/факт ресурсов |
| `069` | зарезервирован (буфер под возможную доработку ресурсного домена перед фазой 2.8) |

Триггеры:
- Единица группы = единица членов
- **Деактивация блокируется для ресурсов, групп И членов группы** при открытых ссылках
- Скопинг SELECT по поддереву: дочерняя зона видит справочники родительской (read-only); запись — только в своей зоне
- Один ресурс может быть в нескольких открытых нарядах — факт суммируется

## 2.8 — close_work_order v2 + гранты + сид

| Миграция | Содержание |
|----------|------------|
| `070_close_work_order_v2` | Расширение: `resource_facts jsonb`, валидация ресурс/группа, INSERT в *_resource_fact |
| `070a_soft_delete` | Единый `BEFORE DELETE`-триггер `soft_delete()` на все таблицы с `record_status` (§3b audit-spec.md): `DELETE` → `UPDATE status='deprecated'`, физического удаления не происходит. Не входит в исходный состав раздела — добавлен по факту сверки с общим правилом `CLAUDE.md` («DELETE = мягкое удаление»), которое требует, чтобы DELETE-политики не были наглухо заблокированы на доменных таблицах |
| `070b_close_work_order_task_guard` | Исправление `close_work_order`: обязательная проверка `task_id` в каждом элементе `task_facts` (`RAISE PT400`, если пуст или работа не найдена). До правки отсутствующий/невалидный `task_id` не вызывал ошибку — функция писала `work_order_task_fact` и необратимо закрывала наряд без обновления `task`/`percent_done` |
| `071_grants` | Единый идемпотентный скрипт всех привилегий |
| `072_seed` | Навигация, роли, 3 тестовых пользователя, демо-проект с WBS, участки, ресурсы |

## Готово когда

- `POST /rpc/login` → JWT с корректными claims
- `GET /rpc/me` → профиль со `start_route`
- `GET /task` с токеном планировщика → WBS-дерево в зоне видимости
- `GET /menu_item` → отфильтровано по роли
- `POST /rpc/close_work_order` с фактом → percent_done обновляется, роллап работает
- Деактивация ресурса/члена группы при открытом наряде → триггер отклоняет
- login с `disabled`-пользователем → отказ
- Админ не может изменить свою роль → RLS-ошибка

**Оценка:** 14–18 дней
