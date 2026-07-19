-- 040_work_order — наряд (документ диспетчера) + аудит + RLS. Без record_status — 4 состояния
-- через work_order_status (created/open/closed/canceled). Диспетчер CRUD открытых нарядов
-- в org_subtree(); planner/admin — read-only. DELETE запрещён всем (только через cancel_work_order RPC).

CREATE TABLE IF NOT EXISTS work_order (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_unit_id uuid NOT NULL REFERENCES org_unit (id),
  title       text NOT NULL,
  status      work_order_status NOT NULL DEFAULT 'created',
  closed_at   timestamptz,
  created_at  timestamptz,
  created_by  uuid REFERENCES users (id),
  updated_at  timestamptz,
  updated_by  uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS work_order_id_hash_idx ON work_order USING hash (id);
CREATE INDEX IF NOT EXISTS work_order_org_unit_id_hash_idx ON work_order USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS work_order_created_by_hash_idx ON work_order USING hash (created_by);
CREATE INDEX IF NOT EXISTS work_order_updated_by_hash_idx ON work_order USING hash (updated_by);

DROP TRIGGER IF EXISTS work_order_default_org_trg ON work_order;
CREATE TRIGGER work_order_default_org_trg
  BEFORE INSERT ON work_order
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS work_order_audit_trg ON work_order;
CREATE TRIGGER work_order_audit_trg
  BEFORE INSERT OR UPDATE ON work_order
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

ALTER TABLE work_order ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_order FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_order_select ON work_order;
CREATE POLICY work_order_select ON work_order
  FOR SELECT
  USING (org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS work_order_insert ON work_order;
CREATE POLICY work_order_insert ON work_order
  FOR INSERT
  WITH CHECK (
    current_role_code() = 'dispatcher'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

-- UPDATE через REST разрешён диспетчеру только пока created/open (редактирование состава через
-- work_order_task); переход в closed/canceled — только через RPC issue/cancel/close_work_order
-- (SECURITY DEFINER, обходит RLS для самого перехода статуса, но не для состава).
DROP POLICY IF EXISTS work_order_update ON work_order;
CREATE POLICY work_order_update ON work_order
  FOR UPDATE
  USING (
    current_role_code() = 'dispatcher'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
    AND status IN ('created', 'open')
  )
  WITH CHECK (
    current_role_code() = 'dispatcher'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS work_order_delete ON work_order;
CREATE POLICY work_order_delete ON work_order
  FOR DELETE
  USING (false); -- только через cancel_work_order() RPC
