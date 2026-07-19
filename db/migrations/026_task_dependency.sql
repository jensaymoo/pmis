-- 026_task_dependency — зависимости сиблингов (FS/SS/FF/SF + lag) + аудит + RLS;
-- гарды: сиблинг, зона, проект, отсутствие циклов.

CREATE TABLE IF NOT EXISTS task_dependency (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id uuid NOT NULL REFERENCES project (id),
  from_id    uuid NOT NULL REFERENCES task (id) ON DELETE CASCADE,
  to_id      uuid NOT NULL REFERENCES task (id) ON DELETE CASCADE,
  type       dependency_type NOT NULL DEFAULT 'FS',
  lag        numeric NOT NULL DEFAULT 0,
  status     record_status NOT NULL DEFAULT 'created',
  created_at timestamptz,
  created_by uuid REFERENCES users (id),
  updated_at timestamptz,
  updated_by uuid REFERENCES users (id),
  CONSTRAINT task_dependency_no_self CHECK (from_id <> to_id),
  CONSTRAINT task_dependency_unique UNIQUE (from_id, to_id)
);

CREATE INDEX IF NOT EXISTS task_dependency_id_hash_idx ON task_dependency USING hash (id);
CREATE INDEX IF NOT EXISTS task_dependency_project_id_hash_idx ON task_dependency USING hash (project_id);
CREATE INDEX IF NOT EXISTS task_dependency_from_id_hash_idx ON task_dependency USING hash (from_id);
CREATE INDEX IF NOT EXISTS task_dependency_to_id_hash_idx ON task_dependency USING hash (to_id);

DROP TRIGGER IF EXISTS task_dependency_audit_trg ON task_dependency;
CREATE TRIGGER task_dependency_audit_trg
  BEFORE INSERT OR UPDATE ON task_dependency
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- Теперь, когда task_dependency существует, навешиваем отложенный AFTER-триггер на task
-- (025_task_triggers.sql определил функцию, но не создавал триггер — таблицы ещё не было).
DROP TRIGGER IF EXISTS task_recheck_deps_trg ON task;
CREATE TRIGGER task_recheck_deps_trg
  AFTER UPDATE OF org_unit_id ON task
  FOR EACH ROW EXECUTE FUNCTION task_recheck_dependencies_on_org_change();

-- ---------------------------------------------------------------------------
-- Гарды
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION task_dependency_check_guards() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_from task%ROWTYPE;
  v_to task%ROWTYPE;
  v_has_cycle boolean;
BEGIN
  SELECT * INTO v_from FROM task WHERE id = NEW.from_id;
  SELECT * INTO v_to FROM task WHERE id = NEW.to_id;

  IF NOT FOUND OR v_from.id IS NULL THEN
    RAISE EXCEPTION 'Работа-источник зависимости не найдена';
  END IF;

  -- Сиблинг-гард: общий родитель (включая оба NULL — оба корневые).
  IF v_from.parent_id IS DISTINCT FROM v_to.parent_id THEN
    RAISE EXCEPTION 'Зависимость допускается только между работами с общим родителем (сиблингами)';
  END IF;

  -- Проектный гард.
  IF v_from.project_id <> NEW.project_id OR v_to.project_id <> NEW.project_id THEN
    RAISE EXCEPTION 'Зависимость должна принадлежать тому же проекту, что и обе работы';
  END IF;

  -- Зонный гард: from и to в одном org_subtree() (той же зоне или её поддереве относительно
  -- текущего пользователя) — проверяем совпадение org_unit_id напрямую (та же зона).
  IF v_from.org_unit_id <> v_to.org_unit_id THEN
    RAISE EXCEPTION 'Зависимость между работами разных зон ответственности запрещена';
  END IF;

  -- Циклический гард: рекурсивный обход от to_id по существующим зависимостям не должен достичь from_id.
  WITH RECURSIVE reach AS (
    SELECT to_id AS node FROM task_dependency WHERE from_id = NEW.to_id AND status <> 'deprecated'
    UNION
    SELECT td.to_id FROM task_dependency td JOIN reach r ON td.from_id = r.node WHERE td.status <> 'deprecated'
  )
  SELECT EXISTS (SELECT 1 FROM reach WHERE node = NEW.from_id) INTO v_has_cycle;

  IF v_has_cycle THEN
    RAISE EXCEPTION 'Зависимость создаёт цикл в графе работ';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS task_dependency_guards_trg ON task_dependency;
CREATE TRIGGER task_dependency_guards_trg
  BEFORE INSERT OR UPDATE ON task_dependency
  FOR EACH ROW EXECUTE FUNCTION task_dependency_check_guards();

-- ---------------------------------------------------------------------------
-- RLS: planner — CRUD в org_subtree() через project_id -> project.org_unit_id;
-- dispatcher — SELECT; admin — CRUD в org_subtree().
-- ---------------------------------------------------------------------------
ALTER TABLE task_dependency ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_dependency FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS task_dependency_select ON task_dependency;
CREATE POLICY task_dependency_select ON task_dependency
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM project p
      WHERE p.id = task_dependency.project_id
        AND p.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_dependency_insert ON task_dependency;
CREATE POLICY task_dependency_insert ON task_dependency
  FOR INSERT
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM project p
      WHERE p.id = task_dependency.project_id
        AND p.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_dependency_update ON task_dependency;
CREATE POLICY task_dependency_update ON task_dependency
  FOR UPDATE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM project p
      WHERE p.id = task_dependency.project_id
        AND p.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  )
  WITH CHECK (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM project p
      WHERE p.id = task_dependency.project_id
        AND p.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  );

DROP POLICY IF EXISTS task_dependency_delete ON task_dependency;
CREATE POLICY task_dependency_delete ON task_dependency
  FOR DELETE
  USING (
    current_role_code() IN ('admin', 'planner')
    AND EXISTS (
      SELECT 1 FROM project p
      WHERE p.id = task_dependency.project_id
        AND p.org_unit_id IN (SELECT id FROM current_org_subtree())
    )
  ); -- физический DELETE перехватывается soft_delete()-триггером (070a) -> UPDATE status='deprecated'
