-- 024_task_rls — RLS на task: planner/admin — CRUD в org_subtree(); dispatcher — read-only.

ALTER TABLE task ENABLE ROW LEVEL SECURITY;
ALTER TABLE task FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS task_select ON task;
CREATE POLICY task_select ON task
  FOR SELECT
  USING (org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS task_insert ON task;
CREATE POLICY task_insert ON task
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS task_update ON task;
CREATE POLICY task_update ON task
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS task_delete ON task;
CREATE POLICY task_delete ON task
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
