-- 051_personnel_resource — ресурс персонала + аудит + RLS + блокировка смены unit_id пока в группе.

CREATE TABLE IF NOT EXISTS personnel_resource (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  name        text NOT NULL,
  description text,
  unit_id     uuid NOT NULL REFERENCES personnel_unit (id),
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS personnel_resource_id_hash_idx ON personnel_resource USING hash (id);
CREATE INDEX IF NOT EXISTS personnel_resource_org_unit_id_hash_idx ON personnel_resource USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS personnel_resource_unit_id_hash_idx ON personnel_resource USING hash (unit_id);

DROP TRIGGER IF EXISTS personnel_resource_default_org_trg ON personnel_resource;
CREATE TRIGGER personnel_resource_default_org_trg
  BEFORE INSERT ON personnel_resource
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS personnel_resource_audit_trg ON personnel_resource;
CREATE TRIGGER personnel_resource_audit_trg
  BEFORE INSERT OR UPDATE ON personnel_resource
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

CREATE OR REPLACE FUNCTION personnel_resource_guard_unit_change() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
    IF EXISTS (SELECT 1 FROM personnel_group_resource WHERE resource_id = NEW.id AND status <> 'deprecated') THEN
      RAISE EXCEPTION 'Нельзя сменить единицу измерения ресурса, пока он состоит в группе';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS personnel_resource_unit_change_trg ON personnel_resource;
CREATE TRIGGER personnel_resource_unit_change_trg
  BEFORE UPDATE OF unit_id ON personnel_resource
  FOR EACH ROW EXECUTE FUNCTION personnel_resource_guard_unit_change();

-- Блокировка деактивации при открытых ссылках (наряд created/open использующий ресурс, либо
-- незавершённая работа с таким нарядом) — реализовано через open-ссылки в *_resource_plan/*_resource_fact
-- и work_order_task/work_order цепочку. Единая функция ниже используется для personnel/equipment/materials
-- по аналогии (каждый домен свою версию, т.к. имена таблиц разные).
CREATE OR REPLACE FUNCTION personnel_resource_guard_deactivate() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_open_ref boolean;
BEGIN
  IF NEW.status IN ('disabled', 'deprecated') AND OLD.status <> NEW.status THEN
    -- Открытая ссылка: плановое назначение (через group_resource или напрямую) на строку дневного
    -- плана, чья работа связана с открытым (created/open) нарядом.
    SELECT EXISTS (
      SELECT 1
      FROM personnel_resource_plan prp
      JOIN task_daily_plan tdp ON tdp.id = prp.task_daily_plan_id
      JOIN work_order_task wot ON wot.task_daily_plan_id = tdp.id
      JOIN work_order wo ON wo.id = wot.work_order_id AND wo.status IN ('created', 'open')
      WHERE prp.resource_id = NEW.id
         OR prp.group_id IN (SELECT group_id FROM personnel_group_resource WHERE resource_id = NEW.id)
    ) INTO v_open_ref;

    IF v_open_ref THEN
      RAISE EXCEPTION 'Нельзя деактивировать ресурс: есть открытый наряд (created/open), использующий его';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS personnel_resource_deactivate_guard_trg ON personnel_resource;
CREATE TRIGGER personnel_resource_deactivate_guard_trg
  BEFORE UPDATE OF status ON personnel_resource
  FOR EACH ROW EXECUTE FUNCTION personnel_resource_guard_deactivate();

ALTER TABLE personnel_resource ENABLE ROW LEVEL SECURITY;
ALTER TABLE personnel_resource FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS personnel_resource_select ON personnel_resource;
CREATE POLICY personnel_resource_select ON personnel_resource
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

DROP POLICY IF EXISTS personnel_resource_insert ON personnel_resource;
CREATE POLICY personnel_resource_insert ON personnel_resource
  FOR INSERT
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS personnel_resource_update ON personnel_resource;
CREATE POLICY personnel_resource_update ON personnel_resource
  FOR UPDATE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()))
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS personnel_resource_delete ON personnel_resource;
CREATE POLICY personnel_resource_delete ON personnel_resource
  FOR DELETE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));
