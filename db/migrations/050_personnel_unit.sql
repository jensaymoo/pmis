-- 050_personnel_unit — единица измерения персонала + аудит + RLS (тот же паттерн скоупинга, что qty_unit).

CREATE TABLE IF NOT EXISTS personnel_unit (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  name        text NOT NULL,
  short_name  text NOT NULL,
  is_integer  boolean NOT NULL DEFAULT false,
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS personnel_unit_id_hash_idx ON personnel_unit USING hash (id);
CREATE INDEX IF NOT EXISTS personnel_unit_org_unit_id_hash_idx ON personnel_unit USING hash (org_unit_id);

DROP TRIGGER IF EXISTS personnel_unit_default_org_trg ON personnel_unit;
CREATE TRIGGER personnel_unit_default_org_trg
  BEFORE INSERT ON personnel_unit
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS personnel_unit_audit_trg ON personnel_unit;
CREATE TRIGGER personnel_unit_audit_trg
  BEFORE INSERT OR UPDATE ON personnel_unit
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

ALTER TABLE personnel_unit ENABLE ROW LEVEL SECURITY;
ALTER TABLE personnel_unit FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS personnel_unit_select ON personnel_unit;
CREATE POLICY personnel_unit_select ON personnel_unit
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

DROP POLICY IF EXISTS personnel_unit_insert ON personnel_unit;
CREATE POLICY personnel_unit_insert ON personnel_unit
  FOR INSERT
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS personnel_unit_update ON personnel_unit;
CREATE POLICY personnel_unit_update ON personnel_unit
  FOR UPDATE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()))
  WITH CHECK (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS personnel_unit_delete ON personnel_unit;
CREATE POLICY personnel_unit_delete ON personnel_unit
  FOR DELETE
  USING (current_role_code() IN ('admin', 'planner') AND org_unit_id IN (SELECT id FROM current_org_subtree()));
