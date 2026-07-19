-- 058_equipment_group — группа техники + аудит + RLS + блокировка смены unit_id пока есть привязанные ресурсы.

CREATE TABLE IF NOT EXISTS equipment_group (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  name        text NOT NULL,
  unit_id     uuid NOT NULL REFERENCES equipment_unit (id),
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS equipment_group_id_hash_idx ON equipment_group USING hash (id);
CREATE INDEX IF NOT EXISTS equipment_group_org_unit_id_hash_idx ON equipment_group USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS equipment_group_unit_id_hash_idx ON equipment_group USING hash (unit_id);

DROP TRIGGER IF EXISTS equipment_group_default_org_trg ON equipment_group;
CREATE TRIGGER equipment_group_default_org_trg
  BEFORE INSERT ON equipment_group
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS equipment_group_audit_trg ON equipment_group;
CREATE TRIGGER equipment_group_audit_trg
  BEFORE INSERT OR UPDATE ON equipment_group
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

CREATE OR REPLACE FUNCTION equipment_group_guard_unit_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
    IF EXISTS (SELECT 1 FROM equipment_group_resource WHERE group_id = NEW.id AND status <> 'deprecated') THEN
      RAISE EXCEPTION 'Нельзя сменить единицу измерения группы, пока есть привязанные ресурсы';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS equipment_group_unit_change_trg ON equipment_group;
CREATE TRIGGER equipment_group_unit_change_trg
  BEFORE UPDATE OF unit_id ON equipment_group
  FOR EACH ROW EXECUTE FUNCTION equipment_group_guard_unit_change();

CREATE OR REPLACE FUNCTION equipment_group_guard_deactivate() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_open_ref boolean;
BEGIN
  IF NEW.status IN ('disabled', 'deprecated') AND OLD.status <> NEW.status THEN
    SELECT EXISTS (
      SELECT 1
      FROM equipment_resource_plan prp
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

DROP TRIGGER IF EXISTS equipment_group_deactivate_guard_trg ON equipment_group;
CREATE TRIGGER equipment_group_deactivate_guard_trg
  BEFORE UPDATE OF status ON equipment_group
  FOR EACH ROW EXECUTE FUNCTION equipment_group_guard_deactivate();

ALTER TABLE equipment_group ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_group FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS equipment_group_select ON equipment_group;
CREATE POLICY equipment_group_select ON equipment_group
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

DROP POLICY IF EXISTS equipment_group_insert ON equipment_group;
CREATE POLICY equipment_group_insert ON equipment_group
  FOR INSERT
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS equipment_group_update ON equipment_group;
CREATE POLICY equipment_group_update ON equipment_group
  FOR UPDATE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()))
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS equipment_group_delete ON equipment_group;
CREATE POLICY equipment_group_delete ON equipment_group
  FOR DELETE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));
