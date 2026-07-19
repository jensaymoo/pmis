-- 030_section — участок выполнения (area/linear), переиспользуемая сущность уровня org_unit + аудит + RLS.

CREATE TABLE IF NOT EXISTS section (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id   uuid NOT NULL REFERENCES org_unit (id),
  name          text NOT NULL,
  kind          section_kind NOT NULL,
  is_geographic boolean NOT NULL DEFAULT false,
  status        record_status NOT NULL DEFAULT 'created',
  created_at    timestamptz,
  created_by    uuid REFERENCES users (id),
  updated_at    timestamptz,
  updated_by    uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS section_id_hash_idx ON section USING hash (id);
CREATE INDEX IF NOT EXISTS section_org_unit_id_hash_idx ON section USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS section_created_by_hash_idx ON section USING hash (created_by);
CREATE INDEX IF NOT EXISTS section_updated_by_hash_idx ON section USING hash (updated_by);

DROP TRIGGER IF EXISTS section_default_org_trg ON section;
CREATE TRIGGER section_default_org_trg
  BEFORE INSERT ON section
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS section_audit_trg ON section;
CREATE TRIGGER section_audit_trg
  BEFORE INSERT OR UPDATE ON section
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

ALTER TABLE section ENABLE ROW LEVEL SECURITY;
ALTER TABLE section FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS section_select ON section;
CREATE POLICY section_select ON section
  FOR SELECT
  USING (org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS section_insert ON section;
CREATE POLICY section_insert ON section
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS section_update ON section;
CREATE POLICY section_update ON section
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS section_delete ON section;
CREATE POLICY section_delete ON section
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
