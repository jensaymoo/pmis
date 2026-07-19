-- 041a_work_order_task_fact — факт строки наряда (фактический объём и даты), пишется только
-- close_work_order(). Не пронумерована явно в roadmap/02-data-schema.md (там перечислены только
-- 040/041/042/043), но таблица документирована в backend-fact-and-work-orders.md и физически
-- необходима до 043 (close_work_order ссылается на неё). Решение: вставляем как 041a сразу после
-- work_order_task, на которую она ссылается.

CREATE TABLE IF NOT EXISTS work_order_task_fact (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_task_id  uuid NOT NULL REFERENCES work_order_task (id) ON DELETE CASCADE,
  fact_qty            numeric NOT NULL,
  actual_start        timestamptz,
  actual_end          timestamptz,
  created_at          timestamptz,
  created_by          uuid REFERENCES users (id),
  updated_at          timestamptz,
  updated_by          uuid REFERENCES users (id)
);

CREATE INDEX IF NOT EXISTS work_order_task_fact_id_hash_idx ON work_order_task_fact USING hash (id);
CREATE INDEX IF NOT EXISTS work_order_task_fact_wot_id_hash_idx ON work_order_task_fact USING hash (work_order_task_id);

DROP TRIGGER IF EXISTS work_order_task_fact_audit_trg ON work_order_task_fact;
CREATE TRIGGER work_order_task_fact_audit_trg
  BEFORE INSERT OR UPDATE ON work_order_task_fact
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- Гард удаления: запрещает DELETE, если существует любая *_resource_fact с work_order_task_fact_id = OLD.id.
CREATE OR REPLACE FUNCTION work_order_task_fact_guard_delete() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_exists boolean;
BEGIN
  IF to_regclass('public.personnel_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM personnel_resource_fact WHERE work_order_task_fact_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить факт строки наряда: есть фактические назначения ресурсов';
    END IF;
  END IF;
  IF to_regclass('public.equipment_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM equipment_resource_fact WHERE work_order_task_fact_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить факт строки наряда: есть фактические назначения ресурсов';
    END IF;
  END IF;
  IF to_regclass('public.materials_resource_fact') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM materials_resource_fact WHERE work_order_task_fact_id = $1)'
      INTO v_exists USING OLD.id;
    IF v_exists THEN
      RAISE EXCEPTION 'Нельзя удалить факт строки наряда: есть фактические назначения ресурсов';
    END IF;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS work_order_task_fact_guard_delete_trg ON work_order_task_fact;
CREATE TRIGGER work_order_task_fact_guard_delete_trg
  BEFORE DELETE ON work_order_task_fact
  FOR EACH ROW EXECUTE FUNCTION work_order_task_fact_guard_delete();

-- RLS: SELECT read-only всем трём ролям (в пределах org_subtree через work_order); INSERT/UPDATE/DELETE
-- запрещены — пишется только close_work_order() (SECURITY DEFINER, обходит RLS через собственные привилегии).
ALTER TABLE work_order_task_fact ENABLE ROW LEVEL SECURITY;
ALTER TABLE work_order_task_fact FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS work_order_task_fact_select ON work_order_task_fact;
CREATE POLICY work_order_task_fact_select ON work_order_task_fact
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM work_order_task wot
      JOIN work_order wo ON wo.id = wot.work_order_id
      WHERE wot.id = work_order_task_fact.work_order_task_id
        AND wo.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS work_order_task_fact_insert ON work_order_task_fact;
CREATE POLICY work_order_task_fact_insert ON work_order_task_fact FOR INSERT WITH CHECK (false);

DROP POLICY IF EXISTS work_order_task_fact_update ON work_order_task_fact;
CREATE POLICY work_order_task_fact_update ON work_order_task_fact FOR UPDATE USING (false);

DROP POLICY IF EXISTS work_order_task_fact_delete ON work_order_task_fact;
CREATE POLICY work_order_task_fact_delete ON work_order_task_fact FOR DELETE USING (false);
