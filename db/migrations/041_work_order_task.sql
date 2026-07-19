-- 041_work_order_task — строка наряда (плановая привязка работы к наряду через task_daily_plan) + аудит + RLS.
-- Без record_status. SELECT/INSERT/UPDATE — диспетчер (для нарядов created/open); DELETE запрещён (только cancel).

CREATE TABLE IF NOT EXISTS work_order_task (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id       uuid NOT NULL REFERENCES work_order (id) ON DELETE CASCADE,
  task_daily_plan_id  uuid REFERENCES task_daily_plan (id),
  created_at          timestamptz,
  created_by          uuid REFERENCES users (id),
  updated_at          timestamptz,
  updated_by          uuid REFERENCES users (id),
  CONSTRAINT work_order_task_unique UNIQUE (work_order_id, task_daily_plan_id)
);

CREATE INDEX IF NOT EXISTS work_order_task_id_hash_idx ON work_order_task USING hash (id);
CREATE INDEX IF NOT EXISTS work_order_task_work_order_id_hash_idx ON work_order_task USING hash (work_order_id);
CREATE INDEX IF NOT EXISTS work_order_task_task_daily_plan_id_hash_idx ON work_order_task USING hash (task_daily_plan_id);

DROP TRIGGER IF EXISTS work_order_task_audit_trg ON work_order_task;
CREATE TRIGGER work_order_task_audit_trg
  BEFORE INSERT OR UPDATE ON work_order_task
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

ALTER TABLE work_order_task ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_order_task FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_order_task_select ON work_order_task;
CREATE POLICY work_order_task_select ON work_order_task
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM work_order wo
      WHERE wo.id = work_order_task.work_order_id AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS work_order_task_insert ON work_order_task;
CREATE POLICY work_order_task_insert ON work_order_task
  FOR INSERT
  WITH CHECK (
    current_role_code() = 'dispatcher'
    AND EXISTS (
      SELECT 1 FROM work_order wo
      WHERE wo.id = work_order_task.work_order_id
        AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
        AND wo.status IN ('created', 'open')
    )
  );

DROP POLICY IF EXISTS work_order_task_update ON work_order_task;
CREATE POLICY work_order_task_update ON work_order_task
  FOR UPDATE
  USING (
    current_role_code() = 'dispatcher'
    AND EXISTS (
      SELECT 1 FROM work_order wo
      WHERE wo.id = work_order_task.work_order_id
        AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
        AND wo.status IN ('created', 'open')
    )
  )
  WITH CHECK (
    current_role_code() = 'dispatcher'
    AND EXISTS (
      SELECT 1 FROM work_order wo
      WHERE wo.id = work_order_task.work_order_id
        AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS work_order_task_delete ON work_order_task;
CREATE POLICY work_order_task_delete ON work_order_task
  FOR DELETE
  USING (false); -- удаление строк только через cancel_work_order() (строки остаются) — прямого DELETE через REST нет
