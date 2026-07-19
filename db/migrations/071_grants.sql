-- 071_grants — единый идемпотентный скрипт всех привилегий на доменные объекты, гарантированно
-- соответствующий ролям после любых изменений (backend-spec.md §6). Безопасно перезапускать.
-- Реальные ограничения на уровне строк/операций обеспечивает RLS (политики уже созданы в
-- предыдущих миграциях); GRANT здесь — базовый уровень "какие SQL-команды роль вообще может
-- выполнять над таблицей", без которого PostgreSQL отклонит запрос ДО того, как RLS успеет
-- сработать.

-- ---------------------------------------------------------------------------
-- Схема
-- ---------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, admin, planner, dispatcher;

-- ---------------------------------------------------------------------------
-- Seed-only справочники (screen, roles, menu_item) — SELECT всем прикладным ролям.
-- menu_item дополнительно фильтруется RLS по role_code (017_nav_rls.sql).
-- ---------------------------------------------------------------------------
GRANT SELECT ON screen, roles TO anon, admin, planner, dispatcher;
GRANT SELECT ON menu_item TO admin, planner, dispatcher;

-- ---------------------------------------------------------------------------
-- org_unit — CRUD только admin (RLS ограничивает org_subtree()); planner/dispatcher — SELECT
-- (не имеют записи в org_unit, но им может понадобиться прочитать имя своей организации).
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON org_unit TO admin;
GRANT SELECT ON org_unit TO planner, dispatcher;

-- ---------------------------------------------------------------------------
-- users — admin CRUD (RLS: org_subtree + анти-эскалация); planner/dispatcher read-only.
-- password (bcrypt-хеш) НЕ выдаётся через REST ни одной роли (access-and-roles-api.md:
-- "поле password не возвращается через API по соображениям безопасности") — реализовано
-- column-level GRANT (явный список колонок SELECT без password), а не полагаясь на клиентский
-- select=. INSERT/UPDATE колонки password разрешены (клиент передаёт plaintext при создании/
-- смене — единственный легитимный путь записи; при этом bcrypt-триггер сразу перезаписывает
-- значение хешем до COMMIT, поэтому "утечка" через RETURNING невозможна: возвращаемая после
-- INSERT/UPDATE строка тоже проходит через тот же SELECT column-list без password).
-- ---------------------------------------------------------------------------
-- REVOKE первым: GRANT SELECT(columns) добавляет права, а не заменяет широкий GRANT SELECT ON
-- users (если тот уже был выдан ранее) — явный REVOKE ALL гарантирует чистое состояние перед
-- точечным column-level GRANT, что и делает этот скрипт идемпотентным относительно повторных
-- запусков после предыдущих (более широких) версий грантов.
REVOKE ALL (password) ON users FROM admin, planner, dispatcher;
REVOKE SELECT ON users FROM admin, planner, dispatcher;
GRANT SELECT (id, email, full_name, role, org_unit_id, status, failed_attempts, locked_until,
              token_version, created_at, created_by, updated_at, updated_by) ON users TO admin, planner, dispatcher;
GRANT INSERT, UPDATE, DELETE ON users TO admin;

-- ---------------------------------------------------------------------------
-- Структура работ: qty_unit, project, task, task_dependency.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON qty_unit TO admin, planner;
GRANT SELECT ON qty_unit TO dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON project TO admin, planner;
GRANT SELECT ON project TO dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON task TO admin, planner;
GRANT SELECT ON task TO dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON task_dependency TO admin, planner;
GRANT SELECT ON task_dependency TO dispatcher;

-- ---------------------------------------------------------------------------
-- Дневной план.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON task_daily_plan TO admin, planner;
GRANT SELECT ON task_daily_plan TO dispatcher;

-- ---------------------------------------------------------------------------
-- Участки.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON section TO admin, planner;
GRANT SELECT ON section TO dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON section_point TO admin, planner;
GRANT SELECT ON section_point TO dispatcher;

GRANT SELECT, INSERT, UPDATE, DELETE ON task_section TO admin, planner;
GRANT SELECT ON task_section TO dispatcher;

-- ---------------------------------------------------------------------------
-- Наряды и факт.
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON work_order TO dispatcher;
GRANT SELECT ON work_order TO admin, planner;

GRANT SELECT, INSERT, UPDATE ON work_order_task TO dispatcher;
GRANT SELECT ON work_order_task TO admin, planner;

GRANT SELECT ON work_order_task_fact TO admin, planner, dispatcher;
-- INSERT/UPDATE/DELETE на work_order_task_fact НЕ выдаются никому — пишется только
-- close_work_order() (SECURITY DEFINER, владелец функции имеет собственные права на таблицу).

-- ---------------------------------------------------------------------------
-- Ресурсы ×3 (personnel/equipment/materials): unit, resource, group, group_resource, plan — CRUD
-- planner/admin (RLS ограничивает org_subtree и статус); dispatcher — SELECT.
-- *_resource_fact — SELECT всем, запись только через close_work_order().
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
  personnel_unit, personnel_resource, personnel_group, personnel_group_resource, personnel_resource_plan,
  equipment_unit, equipment_resource, equipment_group, equipment_group_resource, equipment_resource_plan,
  materials_unit, materials_resource, materials_group, materials_group_resource, materials_resource_plan
  TO admin, planner;

GRANT SELECT ON
  personnel_unit, personnel_resource, personnel_group, personnel_group_resource, personnel_resource_plan,
  equipment_unit, equipment_resource, equipment_group, equipment_group_resource, equipment_resource_plan,
  materials_unit, materials_resource, materials_group, materials_group_resource, materials_resource_plan
  TO dispatcher;

GRANT SELECT ON personnel_resource_fact, equipment_resource_fact, materials_resource_fact TO admin, planner, dispatcher;

-- Агрегационные VIEW план/факт ресурсов — read-only всем трём ролям.
GRANT SELECT ON personnel_resource_plan_fact, equipment_resource_plan_fact, materials_resource_plan_fact TO admin, planner, dispatcher;

-- ---------------------------------------------------------------------------
-- RPC-функции: EXECUTE уже выдан точечно в соответствующих миграциях (015/016/018/018a/042a/042b/070).
-- Повторяем здесь идемпотентно для полноты единого скрипта восстановления привилегий.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION login(text, text) TO anon;
GRANT EXECUTE ON FUNCTION me() TO admin, planner, dispatcher;
GRANT EXECUTE ON FUNCTION logout() TO admin, planner, dispatcher;
GRANT EXECUTE ON FUNCTION change_password(text, text) TO admin, planner, dispatcher;
GRANT EXECUTE ON FUNCTION issue_work_order(uuid) TO dispatcher;
GRANT EXECUTE ON FUNCTION cancel_work_order(uuid) TO dispatcher;
GRANT EXECUTE ON FUNCTION close_work_order(uuid, jsonb) TO dispatcher;

-- check_token_version() вызывается PostgREST db-pre-request на каждый запрос под ролью запроса —
-- нужен EXECUTE для anon тоже (анонимные запросы, например login, тоже проходят через хук).
GRANT EXECUTE ON FUNCTION check_token_version() TO anon, admin, planner, dispatcher;

-- ---------------------------------------------------------------------------
-- Default privileges: будущие таблицы/функции, создаваемые ролью pmis (владельцем схемы),
-- НЕ получают автоматических прав — каждая новая доменная таблица обязана явно появиться в этом
-- файле (осознанное решение: минимум привилегий по умолчанию, а не "открыто, пока не закрыто").
-- ---------------------------------------------------------------------------
