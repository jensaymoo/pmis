-- 022_project — проект (контейнер верхнего уровня для дерева работ) + аудит + RLS.
-- planner/admin — CRUD в org_subtree(); dispatcher — read-only.

CREATE TABLE IF NOT EXISTS project (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  status      record_status NOT NULL DEFAULT 'created',
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS project_id_hash_idx ON project USING hash (id);
CREATE INDEX IF NOT EXISTS project_org_unit_id_hash_idx ON project USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS project_created_by_hash_idx ON project USING hash (created_by);
CREATE INDEX IF NOT EXISTS project_updated_by_hash_idx ON project USING hash (updated_by);

DROP TRIGGER IF EXISTS project_default_org_trg ON project;
CREATE TRIGGER project_default_org_trg
  BEFORE INSERT ON project
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS project_audit_trg ON project;
CREATE TRIGGER project_audit_trg
  BEFORE INSERT OR UPDATE ON project
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

ALTER TABLE project ENABLE ROW LEVEL SECURITY;
ALTER TABLE project FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS project_select ON project;
CREATE POLICY project_select ON project
  FOR SELECT
  USING (org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS project_insert ON project;
CREATE POLICY project_insert ON project
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS project_update ON project;
CREATE POLICY project_update ON project
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS project_delete ON project;
CREATE POLICY project_delete ON project
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
