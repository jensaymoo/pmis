-- 033_task_section — связь «работа × участок» с плановым объёмом и материализованным фактом.
-- Также добавляет отложенный FK task_daily_plan.task_section_id -> task_section (027 создал
-- колонку без FK, т.к. эта таблица тогда ещё не существовала).

CREATE TABLE IF NOT EXISTS task_section (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id      uuid NOT NULL REFERENCES task (id) ON DELETE CASCADE,
  section_id   uuid NOT NULL REFERENCES section (id),
  plan_qty     numeric NOT NULL,
  fact_qty     numeric NOT NULL DEFAULT 0,
  percent_done numeric NOT NULL DEFAULT 0,
  actual_start timestamptz,
  actual_end   timestamptz,
  status       record_status NOT NULL DEFAULT 'created',
  created_at   timestamptz,
  created_by   uuid REFERENCES users (id),
  updated_at   timestamptz,
  updated_by   uuid REFERENCES users (id),
  CONSTRAINT task_section_unique UNIQUE (task_id, section_id)
);

CREATE INDEX IF NOT EXISTS task_section_id_hash_idx ON task_section USING hash (id);
CREATE INDEX IF NOT EXISTS task_section_task_id_hash_idx ON task_section USING hash (task_id);
CREATE INDEX IF NOT EXISTS task_section_section_id_hash_idx ON task_section USING hash (section_id);

DROP TRIGGER IF EXISTS task_section_audit_trg ON task_section;
CREATE TRIGGER task_section_audit_trg
  BEFORE INSERT OR UPDATE ON task_section
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- Отложенный FK на task_daily_plan (колонка существовала без ограничения с 027).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'task_daily_plan_task_section_id_fkey'
  ) THEN
    ALTER TABLE task_daily_plan
      ADD CONSTRAINT task_daily_plan_task_section_id_fkey
      FOREIGN KEY (task_section_id) REFERENCES task_section (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS task_daily_plan_task_section_fk_hash_idx
  ON task_daily_plan USING hash (task_section_id);

-- CHECK task_daily_plan.task_section_id -> task_section.task_id = task_daily_plan.task_id.
CREATE OR REPLACE FUNCTION task_daily_plan_check_section_match() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.task_section_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM task_section ts WHERE ts.id = NEW.task_section_id AND ts.task_id = NEW.task_id
    ) THEN
      RAISE EXCEPTION 'task_section_id должен принадлежать той же работе (task_id)';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_daily_plan_section_match_trg ON task_daily_plan;
CREATE TRIGGER task_daily_plan_section_match_trg
  BEFORE INSERT OR UPDATE OF task_id, task_section_id ON task_daily_plan
  FOR EACH ROW EXECUTE FUNCTION task_daily_plan_check_section_match();

ALTER TABLE task_section ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_section FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS task_section_select ON task_section;
CREATE POLICY task_section_select ON task_section
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_section.task_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_section_insert ON task_section;
CREATE POLICY task_section_insert ON task_section
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_section.task_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_section_update ON task_section;
CREATE POLICY task_section_update ON task_section
  FOR UPDATE
  USING (
    -- planner/admin для плановых полей; dispatcher никогда не пишет напрямую (факт через close_work_order,
    -- которая SECURITY DEFINER и обходит RLS ограничения на запись через собственные привилегии).
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_section.task_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_section.task_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_section_delete ON task_section;
CREATE POLICY task_section_delete ON task_section
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task t
      WHERE t.id = task_section.task_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
