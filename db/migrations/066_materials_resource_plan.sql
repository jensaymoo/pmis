-- 066_materials_resource_plan — плановое назначение материалов на work_day (через task_daily_plan)
-- + аудит + RLS. CHECK ровно один из resource_id/group_id. Триггер: work_day -> листовая работа;
-- секционированная -> task_section_id обязателен.

CREATE TABLE IF NOT EXISTS materials_resource_plan (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_daily_plan_id  uuid NOT NULL REFERENCES task_daily_plan (id),
  resource_id         uuid REFERENCES materials_resource (id),
  group_id            uuid REFERENCES materials_group (id),
  plan_qty            numeric NOT NULL,
  status              record_status NOT NULL DEFAULT 'created',
  created_at          timestamptz,
  created_by          uuid REFERENCES users (id),
  updated_at          timestamptz,
  updated_by          uuid REFERENCES users (id),
  CONSTRAINT materials_resource_plan_one_of CHECK (
    (resource_id IS NOT NULL AND group_id IS NULL) OR (resource_id IS NULL AND group_id IS NOT NULL)
  ),
  CONSTRAINT materials_resource_plan_unique_resource UNIQUE (task_daily_plan_id, resource_id),
  CONSTRAINT materials_resource_plan_unique_group UNIQUE (task_daily_plan_id, group_id)
);

CREATE INDEX IF NOT EXISTS materials_resource_plan_id_hash_idx ON materials_resource_plan USING hash (id);
CREATE INDEX IF NOT EXISTS materials_resource_plan_tdp_id_hash_idx ON materials_resource_plan USING hash (task_daily_plan_id);
CREATE INDEX IF NOT EXISTS materials_resource_plan_resource_id_hash_idx ON materials_resource_plan USING hash (resource_id);
CREATE INDEX IF NOT EXISTS materials_resource_plan_group_id_hash_idx ON materials_resource_plan USING hash (group_id);

DROP TRIGGER IF EXISTS materials_resource_plan_audit_trg ON materials_resource_plan;
CREATE TRIGGER materials_resource_plan_audit_trg
  BEFORE INSERT OR UPDATE ON materials_resource_plan
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

CREATE OR REPLACE FUNCTION materials_resource_plan_check_leaf() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_task_id uuid;
BEGIN
  SELECT task_id INTO v_task_id FROM task_daily_plan WHERE id = NEW.task_daily_plan_id;
  IF NOT task_is_leaf(v_task_id) THEN
    RAISE EXCEPTION 'Плановое назначение ресурса допускается только для листовых работ';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS materials_resource_plan_leaf_check_trg ON materials_resource_plan;
CREATE TRIGGER materials_resource_plan_leaf_check_trg
  BEFORE INSERT OR UPDATE ON materials_resource_plan
  FOR EACH ROW EXECUTE FUNCTION materials_resource_plan_check_leaf();

ALTER TABLE materials_resource_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE materials_resource_plan FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS materials_resource_plan_select ON materials_resource_plan;
CREATE POLICY materials_resource_plan_select ON materials_resource_plan
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM task_daily_plan tdp JOIN task t ON t.id = tdp.task_id
      WHERE tdp.id = materials_resource_plan.task_daily_plan_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS materials_resource_plan_insert ON materials_resource_plan;
CREATE POLICY materials_resource_plan_insert ON materials_resource_plan
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM task_daily_plan tdp JOIN task t ON t.id = tdp.task_id
      WHERE tdp.id = materials_resource_plan.task_daily_plan_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS materials_resource_plan_update ON materials_resource_plan;
CREATE POLICY materials_resource_plan_update ON materials_resource_plan
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (SELECT 1 FROM task_daily_plan tdp JOIN task t ON t.id = tdp.task_id WHERE tdp.id = materials_resource_plan.task_daily_plan_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree()))
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (SELECT 1 FROM task_daily_plan tdp JOIN task t ON t.id = tdp.task_id WHERE tdp.id = materials_resource_plan.task_daily_plan_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree()))
  );

DROP POLICY IF EXISTS materials_resource_plan_delete ON materials_resource_plan;
CREATE POLICY materials_resource_plan_delete ON materials_resource_plan
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (SELECT 1 FROM task_daily_plan tdp JOIN task t ON t.id = tdp.task_id WHERE tdp.id = materials_resource_plan.task_daily_plan_id AND t.org_unit_id IN (SELECT id FROM current_org_subtree()))
  );
