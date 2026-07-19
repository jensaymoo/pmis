# Фаза 5 — Справочники

> Все CRUD-экраны для управления справочными данными: пользователи, орг-иерархия, ресурсы.

## Документы

| Документ | Что берём |
|----------|-----------|
| `pmis.wiki/docs/access-and-roles-users.md` | UsersGrid, **OrgUnitTree**, CRUD, анти-эскалация, **lifecycle users** |
| `pmis.wiki/docs/resources-personnel.md`, `resources-equipment.md`, `resources-materials.md` | ResourcesGrid, ResourceFormModal (+ readonly), Units, Groups |
| `pmis.wiki/docs/access-and-roles-business.md` | Роли, зоны, анти-эскалация, **деактивация/восстановление users** |
| `pmis.wiki/docs/resources-business.md` | 3 вида, группы, единицы, lifecycle, **блокировка деактивации членов группы** |
| `pmis.wiki/docs/frontend-spec.md` §8 | Адаптеры, naivePostgrest |

## 5.1 — Адаптер данных

- `npm install vue3-openlayers ol` — установка vue3-openlayers (карта предпросмотра геометрии участков, согласно стеку CLAUDE.md)
- `adapters/naivePostgrest.js` — переиспользуемый адаптер: lazy-пагинация, сортировка, фильтрация → postgrest-js query params

## 5.2 — Пользователи и орг-иерархия (`/users`, админ)

- `components/admin/UsersGrid.vue` — `n-data-table` с CRUD
  - Dropdown org_unit — только поддерево админа
  - Dropdown роли — из roles
  - Анти-эскалация: нельзя менять свою роль/зону
  - **Жизненный цикл:** кнопки Activate / Deactivate; деактивация блокируется при незакрытых нарядах/работах
- **`components/admin/OrgUnitTree.vue`** — `n-data-table` с вложенностью, CRUD над `org_unit` (только администратор)
  - Создание узла (указание родителя, наименование)
  - Перемещение (изменение parent_id)
  - Деактивация / восстановление (deprecated → disabled)
  - Видимость — только поддерево админа

**Готово когда:**
- Создание пользователя вне поддерева → ошибка
- Изменение своей роли/зоны → ошибка
- Деактивация пользователя с незакрытыми нарядами → отказ
- Деактивация пользователя без ссылок → `disabled`; восстановление → `enabled`
- Создание org_unit внутри поддерева → успех; вне → отказ RLS
- Новый пользователь логинится и видит только свою зону

## 5.2.5 — Единицы объёма (`/quantity-units`, админ/планировщик)

- `components/references/QtyUnitsGrid.vue` — `n-data-table` с CRUD (плоский грид)
- `components/references/QtyUnitFormModal.vue` — модалка: наименование, сокращение, целочисленность
- Таблица `qty_unit` создаётся в фазе 2 (миграция `021_qty_unit`)

## 5.3 — Ресурсы (`/resources/:kind`, планировщик/админ/диспетчер)

- `components/resources/ResourcesGrid.vue` — таблица, фильтр по статусу, тулбар по роли
- `components/resources/ResourceFormModal.vue` — модалка: name, description, unit, groups, статус + кнопки Activate/Deactivate; prop `readonly` для переиспользования в нарядах
- `components/resources/UnitsTableModal.vue` — inline-edit единиц (полное имя, сокращение, признак целочисленности)
- `components/resources/GroupsTableModal.vue` — inline-edit групп

**Готово когда:**
- `/resources/personnel`, `/resources/equipment`, `/resources/materials` — работают одинаково
- Планировщик: видит created/enabled/disabled, может создавать/редактировать
- Админ: видит все статусы, может восстановить deprecated → disabled (включение обратно — отдельным действием)
- Диспетчер: только чтение
- **Деактивация ресурса/группы/члена группы** с открытой ссылкой → ошибка
- Единица заблокирована если ресурс в группе
- Скопинг: дочерняя зона видит справочники родительской (read-only)

## 5.4 — Участки (модалка справочника, без отдельного маршрута)

- `components/references/SectionsGrid.vue` — модалка справочника «Участки» (грид `n-data-table` + форма):
  - CRUD над `section` (наименование, вид area/linear, флаг geographic)
  - Таблица точек `section_point` (seq, x, y, z) внутри формы участка
  - Предпросмотр геометрии на карте (vue3-openlayers) для geographic участков
  - Переключение area/linear
  - Вызывается из Редактора работы (Гант, фаза 6) как пикер/редактор участков

**Готово когда:**
- CRUD участка + точек работает (минимум точек: linear ≥ 2, area ≥ 3)
- Переключение area/linear меняет подписи координат и требования к точкам
- Географический участок — предпросмотр на карте; негеографический — без предпросмотра
- Модалка переиспользуется из Ганта без дублирования реализации

**Оценка:** входит в 10–13 дней (фаза 5)

**Оценка:** 10–13 дней
