-- 067_materials_resource_fact — фактическое назначение материалов (пишется только close_work_order()).
-- Без record_status. Прямые INSERT/UPDATE/DELETE запрещены через RLS.

CREATE TABLE IF NOT EXISTS materials_resource_fact (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_task_fact_id   uuid NOT NULL REFERENCES work_order_task_fact (id) ON DELETE CASCADE,
  task_daily_plan_id        uuid REFERENCES task_daily_plan (id),
  resource_id               uuid NOT NULL REFERENCES materials_resource (id),
  fact_qty                  numeric NOT NULL,
  created_at                timestamptz,
  created_by                uuid REFERENCES users (id),
  updated_at                timestamptz,
  updated_by                uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS materials_resource_fact_id_hash_idx ON materials_resource_fact USING hash (id);
CREATE INDEX IF NOT EXISTS materials_resource_fact_wotf_id_hash_idx ON materials_resource_fact USING hash (work_order_task_fact_id);
CREATE INDEX IF NOT EXISTS materials_resource_fact_tdp_id_hash_idx ON materials_resource_fact USING hash (task_daily_plan_id);
CREATE INDEX IF NOT EXISTS materials_resource_fact_resource_id_hash_idx ON materials_resource_fact USING hash (resource_id);

DROP TRIGGER IF EXISTS materials_resource_fact_audit_trg ON materials_resource_fact;
CREATE TRIGGER materials_resource_fact_audit_trg
  BEFORE INSERT OR UPDATE ON materials_resource_fact
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- Валидация плана: для планового назначения (task_daily_plan_id NOT NULL) ресурс должен совпасть
-- с materials_resource_plan.resource_id (конкретный) либо входить в group_id (через group_resource).
CREATE OR REPLACE FUNCTION materials_resource_fact_check_plan_match() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_ok boolean;
BEGIN
  IF NEW.task_daily_plan_id IS NULL THEN
    RETURN NEW; -- внеплановый факт — проверка не выполняется
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM materials_resource_plan prp
    WHERE prp.task_daily_plan_id = NEW.task_daily_plan_id
      AND (
        prp.resource_id = NEW.resource_id
        OR (prp.group_id IS NOT NULL AND EXISTS (
          SELECT 1 FROM materials_group_resource pgr
          WHERE pgr.group_id = prp.group_id AND pgr.resource_id = NEW.resource_id AND pgr.status <> 'deprecated'
        ))
      )
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'Фактический ресурс не соответствует плановому назначению (ни конкретный ресурс, ни член назначенной группы)';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS materials_resource_fact_plan_match_trg ON materials_resource_fact;
CREATE TRIGGER materials_resource_fact_plan_match_trg
  BEFORE INSERT ON materials_resource_fact
  FOR EACH ROW EXECUTE FUNCTION materials_resource_fact_check_plan_match();

ALTER TABLE materials_resource_fact ENABLE ROW LEVEL SECURITY;
ALTER TABLE materials_resource_fact FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS materials_resource_fact_select ON materials_resource_fact;
CREATE POLICY materials_resource_fact_select ON materials_resource_fact
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM work_order_task_fact wotf
      JOIN work_order_task wot ON wot.id = wotf.work_order_task_id
      JOIN work_order wo ON wo.id = wot.work_order_id
      WHERE wotf.id = materials_resource_fact.work_order_task_fact_id
        AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS materials_resource_fact_insert ON materials_resource_fact;
CREATE POLICY materials_resource_fact_insert ON materials_resource_fact FOR INSERT WITH CHECK (false);

DROP POLICY IF EXISTS materials_resource_fact_update ON materials_resource_fact;
CREATE POLICY materials_resource_fact_update ON materials_resource_fact FOR UPDATE USING (false);

DROP POLICY IF EXISTS materials_resource_fact_delete ON materials_resource_fact;
CREATE POLICY materials_resource_fact_delete ON materials_resource_fact FOR DELETE USING (false);
