-- 072_seed — эталонные (seed) данные: навигация (screen/menu_item/roles), 3 тестовых пользователя,
-- демо-проект с WBS, участки, ресурсы (backend-spec.md §6-§7). Идемпотентно через ON CONFLICT.
--
-- Единый тестовый пароль для всех трёх учётных записей: Passw0rd! (простой, только для dev-среды;
-- реальный секрет не имеет значения — bcrypt-хеш перезаписывается триггером users_hash_password_trg).

-- ---------------------------------------------------------------------------
-- 1) screen — каталог экранов
-- ---------------------------------------------------------------------------
INSERT INTO screen (code, route) VALUES
  ('gantt', '/gantt'),
  ('works', '/works'),
  ('work_orders', '/work-orders'),
  ('users', '/users'),
  ('resources_personnel', '/resources/personnel'),
  ('resources_equipment', '/resources/equipment'),
  ('resources_materials', '/resources/materials'),
  ('qty_unit', '/quantity-units')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2) roles — справочник ролей со стартовым экраном
--    planner -> gantt, admin -> users, dispatcher -> work_orders (navigation-spec.md §9)
-- ---------------------------------------------------------------------------
INSERT INTO roles (code, name, start_screen_id)
SELECT 'admin', 'Администратор', s.id FROM screen s WHERE s.code = 'users'
ON CONFLICT (code) DO NOTHING;

INSERT INTO roles (code, name, start_screen_id)
SELECT 'planner', 'Планировщик', s.id FROM screen s WHERE s.code = 'gantt'
ON CONFLICT (code) DO NOTHING;

INSERT INTO roles (code, name, start_screen_id)
SELECT 'dispatcher', 'Диспетчер', s.id FROM screen s WHERE s.code = 'work_orders'
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) menu_item — представительный seed (navigation-spec.md / backend-auth-and-navigation.md).
--    planner: Гант, Работы, Наряды(RO для dispatcher), Справочники (Персонал/Техника/Материалы/Ед.объёма)
--    dispatcher: Наряды, Работы(RO), Справочники(RO)
--    admin: Пользователи + комбинированное меню (Планировщик/Диспетчер подменю)
-- ---------------------------------------------------------------------------

-- planner — верхний уровень
INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'planner', NULL, s.id, 'Гант', 10, 'calendar' FROM screen s WHERE s.code = 'gantt'
ON CONFLICT DO NOTHING;

INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'planner', NULL, s.id, 'Работы', 20, 'list' FROM screen s WHERE s.code = 'works'
ON CONFLICT DO NOTHING;

INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'planner', NULL, s.id, 'Наряды', 30, 'file-text' FROM screen s WHERE s.code = 'work_orders'
ON CONFLICT DO NOTHING;

-- planner — «Справочники» (родитель без экрана) + дочерние
DO $$
DECLARE
  v_parent_id uuid;
BEGIN
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  VALUES ('planner', NULL, NULL, 'Справочники', 40, 'folder')
  RETURNING id INTO v_parent_id;

  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'planner', v_parent_id, s.id, 'Персонал', 10, 'users' FROM screen s WHERE s.code = 'resources_personnel';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'planner', v_parent_id, s.id, 'Техника', 20, 'truck' FROM screen s WHERE s.code = 'resources_equipment';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'planner', v_parent_id, s.id, 'Материалы', 30, 'box' FROM screen s WHERE s.code = 'resources_materials';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'planner', v_parent_id, s.id, 'Единицы объёма', 40, 'ruler' FROM screen s WHERE s.code = 'qty_unit';
END $$;

-- dispatcher — верхний уровень
INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'dispatcher', NULL, s.id, 'Наряды', 10, 'file-text' FROM screen s WHERE s.code = 'work_orders'
ON CONFLICT DO NOTHING;

INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'dispatcher', NULL, s.id, 'Работы', 20, 'list' FROM screen s WHERE s.code = 'works'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  v_parent_id uuid;
BEGIN
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  VALUES ('dispatcher', NULL, NULL, 'Справочники', 30, 'folder')
  RETURNING id INTO v_parent_id;

  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'dispatcher', v_parent_id, s.id, 'Персонал', 10, 'users' FROM screen s WHERE s.code = 'resources_personnel';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'dispatcher', v_parent_id, s.id, 'Техника', 20, 'truck' FROM screen s WHERE s.code = 'resources_equipment';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'dispatcher', v_parent_id, s.id, 'Материалы', 30, 'box' FROM screen s WHERE s.code = 'resources_materials';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'dispatcher', v_parent_id, s.id, 'Единицы объёма', 40, 'ruler' FROM screen s WHERE s.code = 'qty_unit';
END $$;

-- admin — комбинированное меню: Пользователи (свой экран) + подменю «Планировщик»/«Диспетчер»
INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'admin', NULL, s.id, 'Пользователи', 10, 'user-cog' FROM screen s WHERE s.code = 'users'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
  v_planner_id uuid;
  v_dispatcher_id uuid;
BEGIN
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  VALUES ('admin', NULL, NULL, 'Планировщик', 20, 'calendar')
  RETURNING id INTO v_planner_id;

  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'admin', v_planner_id, s.id, 'Гант', 10, 'calendar' FROM screen s WHERE s.code = 'gantt';
  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'admin', v_planner_id, s.id, 'Работы', 20, 'list' FROM screen s WHERE s.code = 'works';

  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  VALUES ('admin', NULL, NULL, 'Диспетчер', 30, 'file-text')
  RETURNING id INTO v_dispatcher_id;

  INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
  SELECT 'admin', v_dispatcher_id, s.id, 'Наряды', 10, 'file-text' FROM screen s WHERE s.code = 'work_orders';
END $$;

INSERT INTO menu_item (role_code, parent_id, screen_id, label, sort_order, icon)
SELECT 'admin', NULL, s.id, 'Единицы объёма', 40, 'ruler' FROM screen s WHERE s.code = 'qty_unit'
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4) org_unit — демо-оргструктура: корень + одна дочерняя зона (для проверки поддерева).
-- ---------------------------------------------------------------------------
INSERT INTO org_unit (id, name, status)
VALUES ('00000000-0000-0000-0000-000000000001', 'ООО «ПМИС Демо»', 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO org_unit (id, parent_id, name, status)
VALUES ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001', 'Участок №1', 'enabled')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 5) users — 3 тестовых учётных записи (backend-spec.md §7). Единый пароль: Passw0rd!
--    Все в корневой организации, чтобы упростить сквозные сценарии проверки.
-- ---------------------------------------------------------------------------
INSERT INTO users (id, email, password, full_name, role, org_unit_id, status)
VALUES (
  '00000000-0000-0000-0000-0000000000a1',
  'admin@pmis.local', 'Passw0rd!', 'Администратор Системы', 'admin',
  '00000000-0000-0000-0000-000000000001', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, email, password, full_name, role, org_unit_id, status)
VALUES (
  '00000000-0000-0000-0000-0000000000a2',
  'planner@pmis.local', 'Passw0rd!', 'Планировщик Иванов', 'planner',
  '00000000-0000-0000-0000-000000000001', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, email, password, full_name, role, org_unit_id, status)
VALUES (
  '00000000-0000-0000-0000-0000000000a3',
  'dispatcher@pmis.local', 'Passw0rd!', 'Диспетчер Петров', 'dispatcher',
  '00000000-0000-0000-0000-000000000001', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 6) qty_unit — единицы объёма работ (backend-work-structure.md seed): м, м2, м3, шт, т, кг, компл, ч
--    Создаются в корневой зоне, видны нижестоящим по наследованию (org_ancestors).
-- ---------------------------------------------------------------------------
INSERT INTO qty_unit (id, org_unit_id, name, short_name, is_integer, status) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000001', 'метр', 'м', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000001', 'квадратный метр', 'м2', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-000000000001', 'кубический метр', 'м3', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b4', '00000000-0000-0000-0000-000000000001', 'штука', 'шт', true, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b5', '00000000-0000-0000-0000-000000000001', 'тонна', 'т', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b6', '00000000-0000-0000-0000-000000000001', 'килограмм', 'кг', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b7', '00000000-0000-0000-0000-000000000001', 'комплект', 'компл', true, 'enabled'),
  ('00000000-0000-0000-0000-0000000000b8', '00000000-0000-0000-0000-000000000001', 'час', 'ч', false, 'enabled')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 7) Ресурсные единицы измерения (backend-spec.md §7): чел·ч (персонал), маш·ч (техника),
--    м / шт / кг (материалы).
-- ---------------------------------------------------------------------------
INSERT INTO personnel_unit (id, org_unit_id, name, short_name, is_integer, status)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000001', 'человеко-час', 'чел·ч', false, 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO equipment_unit (id, org_unit_id, name, short_name, is_integer, status)
VALUES ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-000000000001', 'машино-час', 'маш·ч', false, 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO materials_unit (id, org_unit_id, name, short_name, is_integer, status) VALUES
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-000000000001', 'метр', 'м', false, 'enabled'),
  ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-000000000001', 'штука', 'шт', true, 'enabled'),
  ('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-000000000001', 'килограмм', 'кг', false, 'enabled')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 8) Демо-ресурсы: группа персонала «Бригада сварщиков» (2-3 ресурса), группа техники
--    «Трансформаторная установка» (1-2 ресурса), конкретный материал «труба DN200».
-- ---------------------------------------------------------------------------
INSERT INTO personnel_group (id, org_unit_id, name, unit_id, status)
VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000001', 'Бригада сварщиков', '00000000-0000-0000-0000-0000000000c1', 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO personnel_resource (id, org_unit_id, name, description, unit_id, status) VALUES
  ('00000000-0000-0000-0000-0000000000d2', '00000000-0000-0000-0000-000000000001', 'Бригада №1', 'Сварочная бригада №1', '00000000-0000-0000-0000-0000000000c1', 'enabled'),
  ('00000000-0000-0000-0000-0000000000d3', '00000000-0000-0000-0000-000000000001', 'Бригада №2', 'Сварочная бригада №2', '00000000-0000-0000-0000-0000000000c1', 'enabled'),
  ('00000000-0000-0000-0000-0000000000d4', '00000000-0000-0000-0000-000000000001', 'Бригада №3', 'Сварочная бригада №3', '00000000-0000-0000-0000-0000000000c1', 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO personnel_group_resource (group_id, resource_id, status) VALUES
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d2', 'enabled'),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d3', 'enabled'),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000d4', 'enabled')
ON CONFLICT DO NOTHING;

INSERT INTO equipment_group (id, org_unit_id, name, unit_id, status)
VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-000000000001', 'Трансформаторная установка', '00000000-0000-0000-0000-0000000000c2', 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO equipment_resource (id, org_unit_id, name, description, unit_id, status) VALUES
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-000000000001', 'ТС-10', 'Трансформаторная станция ТС-10', '00000000-0000-0000-0000-0000000000c2', 'enabled'),
  ('00000000-0000-0000-0000-0000000000e3', '00000000-0000-0000-0000-000000000001', 'ТС-11', 'Трансформаторная станция ТС-11', '00000000-0000-0000-0000-0000000000c2', 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO equipment_group_resource (group_id, resource_id, status) VALUES
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e2', 'enabled'),
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000e3', 'enabled')
ON CONFLICT DO NOTHING;

INSERT INTO materials_resource (id, org_unit_id, name, description, unit_id, status)
VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-000000000001', 'труба DN200', 'Стальная труба диаметром 200мм', '00000000-0000-0000-0000-0000000000c3', 'enabled')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 9) Демо-проект с WBS + демо-работы для сценариев закрытия нарядов.
-- ---------------------------------------------------------------------------
INSERT INTO project (id, name, org_unit_id, status)
VALUES ('00000000-0000-0000-0000-000000000100', 'Демо-проект: реконструкция сети', '00000000-0000-0000-0000-000000000001', 'enabled')
ON CONFLICT (id) DO NOTHING;

-- Корневая составная работа (без плана — составная).
INSERT INTO task (id, project_id, org_unit_id, name, start_date, end_date, task_type, status)
VALUES (
  '00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000001',
  'Этап 1: Прокладка сетей', '2026-08-01 00:00:00+00', '2026-08-31 00:00:00+00', 'task', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

-- Листовая демо-работа: несекционированная, с групповыми и конкретными назначениями ресурсов.
INSERT INTO task (id, project_id, parent_id, org_unit_id, name, start_date, end_date, plan_qty, qty_unit_id, task_type, status)
VALUES (
  '00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000001', 'Укладка трубы DN200', '2026-08-01 00:00:00+00', '2026-08-10 00:00:00+00',
  100, '00000000-0000-0000-0000-0000000000b1', 'task', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

-- Плановое назначение ресурсов на первый день дневного плана (создан автоматически триггером
-- task_daily_plan_sync_period при INSERT задачи выше).
DO $$
DECLARE
  v_tdp_id uuid;
BEGIN
  SELECT id INTO v_tdp_id FROM task_daily_plan
  WHERE task_id = '00000000-0000-0000-0000-000000000102' AND date = '2026-08-01' AND task_section_id IS NULL;

  IF v_tdp_id IS NOT NULL THEN
    INSERT INTO personnel_resource_plan (task_daily_plan_id, group_id, plan_qty, status)
    VALUES (v_tdp_id, '00000000-0000-0000-0000-0000000000d1', 40, 'enabled')
    ON CONFLICT DO NOTHING;

    INSERT INTO equipment_resource_plan (task_daily_plan_id, group_id, plan_qty, status)
    VALUES (v_tdp_id, '00000000-0000-0000-0000-0000000000e1', 16, 'enabled')
    ON CONFLICT DO NOTHING;

    INSERT INTO materials_resource_plan (task_daily_plan_id, resource_id, plan_qty, status)
    VALUES (v_tdp_id, '00000000-0000-0000-0000-0000000000f1', 3000, 'enabled')
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 10) Демо-участок (секционированная работа для сценариев Участков).
-- ---------------------------------------------------------------------------
INSERT INTO section (id, org_unit_id, name, kind, is_geographic, status)
VALUES ('00000000-0000-0000-0000-000000000200', '00000000-0000-0000-0000-000000000001', 'Трасса №1 (ПК0-ПК10)', 'linear', false, 'enabled')
ON CONFLICT (id) DO NOTHING;

INSERT INTO section_point (section_id, seq, name, x, status) VALUES
  ('00000000-0000-0000-0000-000000000200', 1, 'ПК0', 0, 'enabled'),
  ('00000000-0000-0000-0000-000000000200', 2, 'ПК10', 1000, 'enabled')
ON CONFLICT DO NOTHING;

INSERT INTO task (id, project_id, parent_id, org_unit_id, name, start_date, end_date, task_type, status)
VALUES (
  '00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000100', '00000000-0000-0000-0000-000000000101',
  '00000000-0000-0000-0000-000000000001', 'Земляные работы (секционированная)', '2026-08-01 00:00:00+00', '2026-08-15 00:00:00+00',
  'task', 'enabled'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO task_section (id, task_id, section_id, plan_qty, status)
VALUES ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000200', 1000, 'enabled')
ON CONFLICT (id) DO NOTHING;
