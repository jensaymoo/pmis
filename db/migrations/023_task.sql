-- 023_task — работа (WBS-дерево, parent_id) + аудит + индексы.

CREATE TABLE IF NOT EXISTS task (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id    uuid NOT NULL REFERENCES project (id),
  parent_id     uuid REFERENCES task (id) ON DELETE CASCADE,
  org_unit_id   uuid NOT NULL REFERENCES org_unit (id),
  task_type     task_type NOT NULL DEFAULT 'task',
  name          text NOT NULL,
  start_date    timestamptz NOT NULL,
  end_date      timestamptz NOT NULL,
  duration      numeric,
  plan_qty      numeric,
  qty_unit_id   uuid REFERENCES qty_unit (id),
  percent_done  numeric NOT NULL DEFAULT 0,
  actual_start  timestamptz,
  actual_end    timestamptz,
  status        record_status NOT NULL DEFAULT 'created',
  created_at    timestamptz,
  created_by    uuid REFERENCES users (id),
  updated_at    timestamptz,
  updated_by    uuid REFERENCES users (id),
  CONSTRAINT task_no_self_parent CHECK (id IS DISTINCT FROM parent_id),
  CONSTRAINT task_dates_order CHECK (end_date >= start_date),
  CONSTRAINT task_milestone_percent CHECK (task_type <> 'milestone' OR percent_done IN (0, 100))
);

CREATE INDEX IF NOT EXISTS task_id_hash_idx ON task USING hash (id);
CREATE INDEX IF NOT EXISTS task_project_id_hash_idx ON task USING hash (project_id);
CREATE INDEX IF NOT EXISTS task_parent_id_hash_idx ON task USING hash (parent_id);
CREATE INDEX IF NOT EXISTS task_org_unit_id_hash_idx ON task USING hash (org_unit_id);
CREATE INDEX IF NOT EXISTS task_qty_unit_id_hash_idx ON task USING hash (qty_unit_id);
CREATE INDEX IF NOT EXISTS task_created_by_hash_idx ON task USING hash (created_by);
CREATE INDEX IF NOT EXISTS task_updated_by_hash_idx ON task USING hash (updated_by);
CREATE INDEX IF NOT EXISTS task_start_date_idx ON task USING btree (start_date);
CREATE INDEX IF NOT EXISTS task_end_date_idx ON task USING btree (end_date);
CREATE INDEX IF NOT EXISTS task_actual_start_idx ON task USING btree (actual_start);
CREATE INDEX IF NOT EXISTS task_actual_end_idx ON task USING btree (actual_end);

DROP TRIGGER IF EXISTS task_default_org_trg ON task;
CREATE TRIGGER task_default_org_trg
  BEFORE INSERT ON task
  FOR EACH ROW EXECUTE FUNCTION default_org_unit_id();

DROP TRIGGER IF EXISTS task_audit_trg ON task;
CREATE TRIGGER task_audit_trg
  BEFORE INSERT OR UPDATE ON task
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- task_type = 'leaf'/'composite' не является отдельным ENUM-значением: "лист" vs "составная"
-- в этой схеме — СТРУКТУРНОЕ свойство (наличие/отсутствие дочерних task), а не хранимый признак,
-- что соответствует backend-work-structure.md (ENUM task_type = {task, milestone} — только два
-- значения) и work-structure-business.md п.14 ("переход из листовой в составную = появление
-- подчинённых работ"). Помогающая функция ниже вычисляет "листовость" на лету.
CREATE OR REPLACE FUNCTION task_is_leaf(p_task_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET row_security = off
AS $$
  SELECT NOT EXISTS (SELECT 1 FROM task WHERE parent_id = p_task_id);
$$;
