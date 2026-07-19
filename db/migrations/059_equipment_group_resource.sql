-- 059_equipment_group_resource — связь группа<->ресурс техники (M:N) + аудит + RLS +
-- проверка совпадения единиц измерения + блокировка удаления члена группы при открытом наряде.

CREATE TABLE IF NOT EXISTS equipment_group_resource (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    uuid NOT NULL REFERENCES equipment_group (id) ON DELETE CASCADE,
  resource_id uuid NOT NULL REFERENCES equipment_resource (id) ON DELETE CASCADE,
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id),
  CONSTRAINT equipment_group_resource_unique UNIQUE (group_id, resource_id)
);

CREATE INDEX IF NOT EXISTS equipment_group_resource_id_hash_idx ON equipment_group_resource USING hash (id);
CREATE INDEX IF NOT EXISTS equipment_group_resource_group_id_hash_idx ON equipment_group_resource USING hash (group_id);
CREATE INDEX IF NOT EXISTS equipment_group_resource_resource_id_hash_idx ON equipment_group_resource USING hash (resource_id);

DROP TRIGGER IF EXISTS equipment_group_resource_audit_trg ON equipment_group_resource;
CREATE TRIGGER equipment_group_resource_audit_trg
  BEFORE INSERT OR UPDATE ON equipment_group_resource
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

CREATE OR REPLACE FUNCTION equipment_group_resource_check_unit() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_group_unit uuid;
  v_resource_unit uuid;
BEGIN
  SELECT unit_id INTO v_group_unit FROM equipment_group WHERE id = NEW.group_id;
  SELECT unit_id INTO v_resource_unit FROM equipment_resource WHERE id = NEW.resource_id;
  IF v_group_unit IS DISTINCT FROM v_resource_unit THEN
    RAISE EXCEPTION 'Единица измерения ресурса должна совпадать с единицей измерения группы';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS equipment_group_resource_unit_check_trg ON equipment_group_resource;
CREATE TRIGGER equipment_group_resource_unit_check_trg
  BEFORE INSERT OR UPDATE ON equipment_group_resource
  FOR EACH ROW EXECUTE FUNCTION equipment_group_resource_check_unit();

-- Блокировка деактивации/удаления члена группы при открытом наряде, использующем группу
-- (тот же принцип, что и для самого ресурса/группы — п.22 resources-business.md).
CREATE OR REPLACE FUNCTION equipment_group_resource_guard_deactivate() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_open_ref boolean;
  v_old record;
BEGIN
  v_old := OLD;
  IF (TG_OP = 'DELETE') OR (TG_OP = 'UPDATE' AND NEW.status IN ('disabled', 'deprecated') AND OLD.status <> NEW.status) THEN
    SELECT EXISTS (
      SELECT 1
      FROM equipment_resource_plan prp
      JOIN task_daily_plan tdp ON tdp.id = prp.task_daily_plan_id
      JOIN work_order_task wot ON wot.task_daily_plan_id = tdp.id
      JOIN work_order wo ON wo.id = wot.work_order_id AND wo.status IN ('created', 'open')
      WHERE prp.group_id = v_old.group_id
    ) INTO v_open_ref;

    IF v_open_ref THEN
      RAISE EXCEPTION 'Нельзя деактивировать/удалить члена группы: группа используется в открытом наряде';
    END IF;
  END IF;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS equipment_group_resource_deactivate_guard_trg ON equipment_group_resource;
CREATE TRIGGER equipment_group_resource_deactivate_guard_trg
  BEFORE UPDATE OF status OR DELETE ON equipment_group_resource
  FOR EACH ROW EXECUTE FUNCTION equipment_group_resource_guard_deactivate();

ALTER TABLE equipment_group_resource ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_group_resource FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS equipment_group_resource_select ON equipment_group_resource;
CREATE POLICY equipment_group_resource_select ON equipment_group_resource
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM equipment_group g
      WHERE g.id = equipment_group_resource.group_id
        AND (
          g.org_unit_id IN (SELECT id FROM current_org_subtree())
          OR g.org_unit_id IN (SELECT id FROM org_ancestors(current_org_unit_id()))
        )
    )
  );

DROP POLICY IF EXISTS equipment_group_resource_insert ON equipment_group_resource;
CREATE POLICY equipment_group_resource_insert ON equipment_group_resource
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (SELECT 1 FROM equipment_group g WHERE g.id = equipment_group_resource.group_id AND g.org_unit_id IN (SELECT id FROM current_org_subtree()))
  );

DROP POLICY IF EXISTS equipment_group_resource_update ON equipment_group_resource;
CREATE POLICY equipment_group_resource_update ON equipment_group_resource
  FOR UPDATE
  USING (current_role_code() IN ('admin', 'planner') AND EXISTS (SELECT 1 FROM equipment_group g WHERE g.id = equipment_group_resource.group_id AND g.org_unit_id IN (SELECT id FROM current_org_subtree())))
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND EXISTS (SELECT 1 FROM equipment_group g WHERE g.id = equipment_group_resource.group_id AND g.org_unit_id IN (SELECT id FROM current_org_subtree())));

DROP POLICY IF EXISTS equipment_group_resource_delete ON equipment_group_resource;
CREATE POLICY equipment_group_resource_delete ON equipment_group_resource
  FOR DELETE
  USING (current_role_code() IN ('admin', 'planner') AND EXISTS (SELECT 1 FROM equipment_group g WHERE g.id = equipment_group_resource.group_id AND g.org_unit_id IN (SELECT id FROM current_org_subtree())));
