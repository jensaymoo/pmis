-- 027_task_daily_plan — дневной план: плановый объём на день для работы или участка.
-- task_section_id -> task_section существует физически только с 033 (участки создаются позже
-- по roadmap); FK на task_section добавляется отложенно в 033_task_section.sql, здесь колонка
-- создаётся БЕЗ FK-ограничения (аналогично прочим форвард-ссылкам в этой схеме).

CREATE TABLE IF NOT EXISTS task_daily_plan (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id          uuid NOT NULL REFERENCES task (id),
  task_section_id  uuid, -- FK -> task_section добавляется в 033_task_section.sql
  date             date NOT NULL,
  plan_qty         numeric NOT NULL DEFAULT 0,
  created_at       timestamptz,
  created_by       uuid REFERENCES users (id),
  updated_at       timestamptz,
  updated_by       uuid REFERENCES users (id),
  CONSTRAINT task_daily_plan_unique UNIQUE (task_id, task_section_id, date),
  CONSTRAINT task_daily_plan_qty_nonneg CHECK (plan_qty >= 0)
);

CREATE INDEX IF NOT EXISTS task_daily_plan_id_hash_idx ON task_daily_plan USING hash (id);
CREATE INDEX IF NOT EXISTS task_daily_plan_task_id_hash_idx ON task_daily_plan USING hash (task_id);
CREATE INDEX IF NOT EXISTS task_daily_plan_task_section_id_hash_idx ON task_daily_plan USING hash (task_section_id);
CREATE INDEX IF NOT EXISTS task_daily_plan_date_idx ON task_daily_plan USING btree (date);

DROP TRIGGER IF EXISTS task_daily_plan_audit_trg ON task_daily_plan;
CREATE TRIGGER task_daily_plan_audit_trg
  BEFORE INSERT OR UPDATE ON task_daily_plan
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- ---------------------------------------------------------------------------
-- Триггер синхронизации периода: при INSERT/UPDATE task.start_date/end_date создаёт записи
-- для новых дней (plan_qty=0, на task целиком — task_section_id NULL) и удаляет записи вне
-- периода при отсутствии факта. Секционированные записи (task_section_id NOT NULL) управляются
-- аналогичным механизмом на уровне task_section (034), здесь — базовый случай на task.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_daily_plan_sync_period() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_d date;
BEGIN
  -- Работы с участками (секционированные) не получают daily_plan на уровне task напрямую —
  -- пропускаем, если у работы уже есть task_section (034 отвечает за их дни).
  IF EXISTS (SELECT 1 FROM task_section WHERE task_id = NEW.id) THEN
    RETURN NEW;
  END IF;

  IF NEW.task_type = 'milestone' THEN
    RETURN NEW; -- вехи не имеют дневного плана
  END IF;

  -- Добавить дни периода, которых ещё нет.
  FOR v_d IN SELECT generate_series(NEW.start_date::date, NEW.end_date::date, interval '1 day')::date LOOP
    INSERT INTO task_daily_plan (task_id, task_section_id, date, plan_qty)
    VALUES (NEW.id, NULL, v_d, 0)
    ON CONFLICT (task_id, task_section_id, date) DO NOTHING;
  END LOOP;

  -- Удалить дни вне нового периода, если по ним нет факта.
  -- to_regclass-гард: work_order_task появляется только в 041_work_order_task.sql; до этого
  -- момента (миграции 027..040) таблицы ещё нет, а task уже создаётся и триггерит этот путь —
  -- без гарда любой INSERT/UPDATE task падал бы с "relation does not exist" до применения 041.
  IF to_regclass('public.work_order_task') IS NOT NULL THEN
    DELETE FROM task_daily_plan tdp
    WHERE tdp.task_id = NEW.id
      AND tdp.task_section_id IS NULL
      AND (tdp.date < NEW.start_date::date OR tdp.date > NEW.end_date::date)
      AND NOT EXISTS (
        SELECT 1 FROM work_order_task wot WHERE wot.task_daily_plan_id = tdp.id
      );
  ELSE
    DELETE FROM task_daily_plan tdp
    WHERE tdp.task_id = NEW.id
      AND tdp.task_section_id IS NULL
      AND (tdp.date < NEW.start_date::date OR tdp.date > NEW.end_date::date);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_daily_plan_sync_trg ON task;
CREATE TRIGGER task_daily_plan_sync_trg
  AFTER INSERT OR UPDATE OF start_date, end_date ON task
  FOR EACH ROW EXECUTE FUNCTION task_daily_plan_sync_period();

-- ---------------------------------------------------------------------------
-- Гард удаления: запрещает DELETE, если есть work_order_task (и тем самым work_order_task_fact)
-- или любая *_resource_fact с task_daily_plan_id = OLD.id.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_daily_plan_guard_delete() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_exists boolean;
BEGIN
  -- EXECUTE (динамический SQL) вместо статического EXISTS(...): plpgsql планирует статические
  -- SQL-выражения при первом выполнении функции целиком, поэтому даже "IF to_regclass(...) IS NOT
  -- NULL AND EXISTS (SELECT ... FROM еще_не_существующая_таблица)" падает с "relation does not
  -- exist" на этапе планирования — AND НЕ откладывает разрешение имён отсутствующей таблицы
  -- (подтверждено эмпирически). EXECUTE с текстом запроса откладывает разбор до реального вызова,
  -- когда таблица уже гарантированно создана (041/050/056/062 применены раньше по времени
  -- эксплуатации, а не по номеру этой миграции).
  IF to_regclass('public.work_order_task') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM work_order_task WHERE task_daily_plan_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить запись дневного плана: по ней уже есть строки наряда/факт';
    END IF;
  END IF;

  IF to_regclass('public.personnel_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM personnel_resource_fact WHERE task_daily_plan_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить запись дневного плана: есть фактические назначения ресурсов';
    END IF;
  END IF;

  IF to_regclass('public.equipment_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM equipment_resource_fact WHERE task_daily_plan_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить запись дневного плана: есть фактические назначения ресурсов';
    END IF;
  END IF;

  IF to_regclass('public.materials_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM materials_resource_fact WHERE task_daily_plan_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить запись дневного плана: есть фактические назначения ресурсов';
    END IF;
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS task_daily_plan_guard_delete_trg ON task_daily_plan;
CREATE TRIGGER task_daily_plan_guard_delete_trg
  BEFORE DELETE ON task_daily_plan
  FOR EACH ROW EXECUTE FUNCTION task_daily_plan_guard_delete();

-- ---------------------------------------------------------------------------
-- RLS: наследует видимость от task (через task_id -> task.org_unit_id). planner/admin CRUD,
-- dispatcher read-only (диспетчер не изменяет дневной план, см. daily-plan-business.md п.13).
-- ---------------------------------------------------------------------------
ALTER TABLE task_daily_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_daily_plan FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS task_daily_plan_select ON task_daily_plan;
CREATE POLICY task_daily_plan_select ON task_daily_plan
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_daily_plan.task_id
        AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_daily_plan_insert ON task_daily_plan;
CREATE POLICY task_daily_plan_insert ON task_daily_plan
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_daily_plan.task_id
        AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_daily_plan_update ON task_daily_plan;
CREATE POLICY task_daily_plan_update ON task_daily_plan
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_daily_plan.task_id
        AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_daily_plan.task_id
        AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_daily_plan_delete ON task_daily_plan;
CREATE POLICY task_daily_plan_delete ON task_daily_plan
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_daily_plan.task_id
        AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );
