-- 070a_soft_delete — механизм "мягкого удаления через DELETE" (CLAUDE.md "Общее": DELETE
-- переводит запись в status = 'deprecated'; для получения удалённой записи — Prefer:
-- return=representation). Единая BEFORE DELETE триггер-функция: перехватывает DELETE, вместо
-- физического удаления выполняет UPDATE status='deprecated' и возвращает NULL (отменяет
-- физическое удаление). Применяется на ВСЕ таблицы, несущие record_status (§3b audit-spec.md);
-- таблицы-исключения (work_order, work_order_task, task_daily_plan, work_order_task_fact,
-- *_resource_fact) НЕ несут record_status и НЕ получают этот триггер — их DELETE-политики
-- остаются как есть (заблокированы либо имеют собственную семантику RPC).
--
-- РЕШЕНИЕ ПО НУМЕРАЦИИ: не входит явно в roadmap/02-data-schema.md как отдельная миграция —
-- обнаружено при сверке с backend-spec.md/корневым CLAUDE.md "Общее" после первичной реализации
-- RLS-политик (изначально DELETE был наглухо заблокирован USING(false) на record_status-таблицах,
-- что противоречит контракту API "DELETE = мягкое удаление"). Вставлено как 070a, после
-- close_work_order v2 и до grants/seed, т.к. добавляет DELETE-политики, которым нужны GRANT DELETE
-- в 071 и которые понадобятся seed-проверкам.

-- SECURITY DEFINER: критично для корректной работы поверх RLS. PostgreSQL требует, чтобы
-- обновлённая (NEW) строка UPDATE проходила проверку не только WITH CHECK политики UPDATE, но и
-- политики SELECT той же роли (иначе строка "исчезла бы" из-под RETURNING/видимости в той же
-- транзакции) — подтверждено эмпирически. Политики SELECT планировщика/диспетчера намеренно
-- исключают статус 'deprecated' (backend-resources.md/backend-work-structure.md: "deprecated
-- исключён — область восстановления администратора"), поэтому обычный (SECURITY INVOKER) UPDATE
-- status='deprecated' от лица planner/dispatcher всегда отклонялся бы RLS, несмотря на то что сам
-- DELETE был явно разрешён политикой qty_unit_delete/… (проверка полномочий на удаление уже
-- прошла ДО срабатывания этого триггера). SECURITY DEFINER выполняет внутренний UPDATE от имени
-- владельца функции (pmis, суперпользователь) в обход RLS — авторизация самого действия остаётся
-- полностью под контролем вызывающей DELETE-политики, а не ослабляется этим триггером.
CREATE OR REPLACE FUNCTION soft_delete() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET row_security = off
AS $$
BEGIN
  EXECUTE format('UPDATE %I.%I SET status = ''deprecated'' WHERE id = $1', TG_TABLE_SCHEMA, TG_TABLE_NAME)
    USING OLD.id;
  RETURN NULL; -- отменяет физическое DELETE
END;
$$;

DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'org_unit', 'users', 'qty_unit', 'project', 'task', 'task_dependency',
    'section', 'section_point', 'task_section',
    'personnel_unit', 'personnel_resource', 'personnel_group', 'personnel_group_resource', 'personnel_resource_plan',
    'equipment_unit', 'equipment_resource', 'equipment_group', 'equipment_group_resource', 'equipment_resource_plan',
    'materials_unit', 'materials_resource', 'materials_group', 'materials_group_resource', 'materials_resource_plan'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I_soft_delete_trg ON %I', t, t);
    -- BEFORE DELETE (не INSTEAD OF — это применимо только к VIEW, не к обычным таблицам):
    -- функция soft_delete() сама выполняет UPDATE и возвращает NULL, что отменяет исходный
    -- физический DELETE (стандартный Postgres-паттерн подмены DELETE на BEFORE-триггере).
    EXECUTE format(
      'CREATE TRIGGER %I_soft_delete_trg BEFORE DELETE ON %I FOR EACH ROW EXECUTE FUNCTION soft_delete()',
      t, t
    );
  END LOOP;
END $$;
