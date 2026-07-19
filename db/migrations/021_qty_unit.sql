-- 021_qty_unit — справочник единиц объёма работ (расширяемый без миграции) + аудит + RLS.
-- Скоупинг: тот же паттерн, что и ресурсные справочники (backend-work-structure.md):
-- planner/admin — CRUD в своём org_subtree(); видимость чтения расширяется на вышестоящие зоны;
-- dispatcher — read-only, только enabled.

CREATE TABLE IF NOT EXISTS qty_unit (
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

CREATE INDEX IF NOT EXISTS qty_unit_id_hash_idx ON qty_unit USING hash (id);
CREATE INDEX IF NOT EXISTS qty_unit_org_unit_id_hash_idx ON qty_unit USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS qty_unit_created_by_hash_idx ON qty_unit USING hash (created_by);
CREATE INDEX IF NOT EXISTS qty_unit_updated_by_hash_idx ON qty_unit USING hash (updated_by);

CREATE OR REPLACE FUNCTION default_org_unit_id() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.org_unit_id IS NULL THEN
    NEW.org_unit_id := current_org_unit_id();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS qty_unit_default_org_trg ON qty_unit;
CREATE TRIGGER qty_unit_default_org_trg
  BEFORE INSERT ON qty_unit
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS qty_unit_audit_trg ON qty_unit;
CREATE TRIGGER qty_unit_audit_trg
  BEFORE INSERT OR UPDATE ON qty_unit
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- Ancestors visibility: узел видит справочники СВОЕГО поддерева И всех вышестоящих зон
-- (цепочка parent_id от своей зоны вверх до корня), чтобы дочерняя зона могла использовать
-- единицы родительской зоны. Реализовано отдельной функцией org_ancestors().
CREATE OR REPLACE FUNCTION org_ancestors(node_id uuid) RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET row_security = off
AS $$
  WITH RECURSIVE ancestors AS (
    SELECT o.id, o.parent_id FROM org_unit o WHERE o.id = node_id
    UNION ALL
    SELECT o.id, o.parent_id FROM org_unit o JOIN ancestors a ON o.id = a.parent_id
  )
  SELECT id FROM ancestors;
$$;

ALTER TABLE qty_unit ENABLE ROW LEVEL SECURITY;
ALTER TABLE qty_unit FORCE ROW LEVEL SECURITY;

-- SELECT: свой org_subtree() видит все статусы (кроме deprecated для planner — см. ниже),
-- вышестоящие зоны (org_ancestors) видны read-only и только enabled.
DROP POLICY IF EXISTS qty_unit_select ON qty_unit;
CREATE POLICY qty_unit_select ON qty_unit
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
    OR (
      org_unit_id IN (SELECT id FROM org_ancestors(current_org_unit_id()))
      AND status = 'enabled'
    )
  );

DROP POLICY IF EXISTS qty_unit_insert ON qty_unit;
CREATE POLICY qty_unit_insert ON qty_unit
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS qty_unit_update ON qty_unit;
CREATE POLICY qty_unit_update ON qty_unit
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS qty_unit_delete ON qty_unit;
CREATE POLICY qty_unit_delete ON qty_unit
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
