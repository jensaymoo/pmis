-- 031_section_point — упорядоченная точка (ордината) участка, единственный носитель геометрии.
-- CHECK: географический участок -> y IS NOT NULL (минимум 2D).

CREATE TABLE IF NOT EXISTS section_point (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section_id uuid NOT NULL REFERENCES section (id) ON DELETE CASCADE,
  seq        integer NOT NULL,
  name       text NOT NULL,
  x          numeric NOT NULL,
  y          numeric,
  z          numeric,
  status     record_status NOT NULL DEFAULT 'created',
  created_at timestamptz,
  created_by uuid REFERENCES users (id),
  updated_at timestamptz,
  updated_by uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS section_point_id_hash_idx ON section_point USING hash (id);
CREATE INDEX IF NOT EXISTS section_point_section_id_hash_idx ON section_point USING hash (section_id);

DROP TRIGGER IF EXISTS section_point_audit_trg ON section_point;
CREATE TRIGGER section_point_audit_trg
  BEFORE INSERT OR UPDATE ON section_point
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- CHECK географического минимума 2D — реализовано триггером (не CHECK constraint), т.к.
-- требует JOIN к родительскому section.is_geographic.
CREATE OR REPLACE FUNCTION section_point_check_geographic() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_is_geo boolean;
BEGIN
  SELECT is_geographic INTO v_is_geo FROM section WHERE id = NEW.section_id;
  IF v_is_geo AND NEW.y IS NULL THEN
    RAISE EXCEPTION 'Точка географического участка должна иметь минимум 2 координаты (широта, долгота)';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS section_point_geo_check_trg ON section_point;
CREATE TRIGGER section_point_geo_check_trg
  BEFORE INSERT OR UPDATE ON section_point
  FOR EACH ROW EXECUTE FUNCTION section_point_check_geographic();

-- RLS: наследует видимость от section.
ALTER TABLE section_point ENABLE ROW LEVEL SECURITY;
ALTER TABLE section_point FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS section_point_select ON section_point;
CREATE POLICY section_point_select ON section_point
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM section s
      WHERE s.id = section_point.section_id AND s.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS section_point_insert ON section_point;
CREATE POLICY section_point_insert ON section_point
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM section s
      WHERE s.id = section_point.section_id AND s.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS section_point_update ON section_point;
CREATE POLICY section_point_update ON section_point
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM section s
      WHERE s.id = section_point.section_id AND s.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM section s
      WHERE s.id = section_point.section_id AND s.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS section_point_delete ON section_point;
CREATE POLICY section_point_delete ON section_point
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM section s
      WHERE s.id = section_point.section_id AND s.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );
