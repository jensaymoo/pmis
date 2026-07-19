-- 064_materials_group — группа материалов + аудит + RLS + блокировка смены unit_id пока есть привязанные ресурсы.

CREATE TABLE IF NOT EXISTS materials_group (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  name        text NOT NULL,
  unit_id     uuid NOT NULL REFERENCES materials_unit (id),
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS materials_group_id_hash_idx ON materials_group USING hash (id);
CREATE INDEX IF NOT EXISTS materials_group_org_unit_id_hash_idx ON materials_group USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS materials_group_unit_id_hash_idx ON materials_group USING hash (unit_id);

DROP TRIGGER IF EXISTS materials_group_default_org_trg ON materials_group;
CREATE TRIGGER materials_group_default_org_trg
  BEFORE INSERT ON materials_group
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS materials_group_audit_trg ON materials_group;
CREATE TRIGGER materials_group_audit_trg
  BEFORE INSERT OR UPDATE ON materials_group
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

CREATE OR REPLACE FUNCTION materials_group_guard_unit_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
    IF EXISTS (SELECT 1 FROM materials_group_resource WHERE group_id = NEW.id AND status <> 'deprecated') THEN
      RAISE EXCEPTION 'Нельзя сменить единицу измерения группы, пока есть привязанные ресурсы';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS materials_group_unit_change_trg ON materials_group;
CREATE TRIGGER materials_group_unit_change_trg
  BEFORE UPDATE OF unit_id ON materials_group
  FOR EACH ROW EXECUTE FUNCTION materials_group_guard_unit_change();

CREATE OR REPLACE FUNCTION materials_group_guard_deactivate() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_open_ref boolean;
BEGIN
  IF NEW.status IN ('disabled', 'deprecated') AND OLD.status <> NEW.status THEN
    SELECT EXISTS (
      SELECT 1
      FROM materials_resource_plan prp
      JOIN task_daily_plan tdp ON tdp.id = prp.task_daily_plan_id
      JOIN work_order_task wot ON wot.task_daily_plan_id = tdp.id
      JOIN work_order wo ON wo.id = wot.work_order_id AND wo.status IN ('created', 'open')
      WHERE prp.group_id = NEW.id
    ) INTO v_open_ref;

    IF v_open_ref THEN
      RAISE EXCEPTION 'Нельзя деактивировать группу: есть открытый наряд (created/open), использующий её';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS materials_group_deactivate_guard_trg ON materials_group;
CREATE TRIGGER materials_group_deactivate_guard_trg
  BEFORE UPDATE OF status ON materials_group
  FOR EACH ROW EXECUTE FUNCTION materials_group_guard_deactivate();

ALTER TABLE materials_group ENABLE ROW LEVEL SECURITY;
ALTER TABLE materials_group FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS materials_group_select ON materials_group;
CREATE POLICY materials_group_select ON materials_group
  FOR SELECT
  USING (
    (
      org_unit_id IN (SELECT id FROM current_org_subtree())
      AND (
        current_role_code() = 'admin'
        OR (current_role_code() = 'planner' AND status <> 'deprecated')
        OR (current_role_code() = 'dispatcher' AND status = 'enabled')
      )
    )
    OR (org_unit_id IN (SELECT id FROM org_ancestors(current_org_unit_id())) AND status = 'enabled')
  );

DROP POLICY IF EXISTS materials_group_insert ON materials_group;
CREATE POLICY materials_group_insert ON materials_group
  FOR INSERT
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS materials_group_update ON materials_group;
CREATE POLICY materials_group_update ON materials_group
  FOR UPDATE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()))
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS materials_group_delete ON materials_group;
CREATE POLICY materials_group_delete ON materials_group
  FOR DELETE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));
