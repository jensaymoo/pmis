-- 013_org_unit — оргструктура (зоны ответственности) + аудит + org_subtree() + RLS.
-- CRUD в рамках поддерева: только admin, в пределах org_subtree(current_org_unit_id()).
-- Планировщик/диспетчер не имеют записи в org_unit (только SELECT в своём поддереве нужен
-- косвенно через прочие таблицы; сам org_unit им на запись не нужен вовсе — см.
-- backend-access-and-roles.md: "Планировщик не имеет записи в org_unit").

CREATE TABLE IF NOT EXISTS org_unit (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id  uuid REFERENCES org_unit (id),
  name       text NOT NULL,
  status     record_status NOT NULL DEFAULT 'created',
  created_at timestamptz,
  created_by uuid,
  updated_at timestamptz,
  updated_by uuid,
  CONSTRAINT org_unit_no_self_parent CHECK (id IS DISTINCT FROM parent_id)
);

CREATE INDEX IF NOT EXISTS org_unit_id_hash_idx ON org_unit USING hash (id);
CREATE INDEX IF NOT EXISTS org_unit_parent_id_hash_idx ON org_unit USING hash (parent_id);

DROP TRIGGER IF EXISTS org_unit_audit_trg ON org_unit;
CREATE TRIGGER org_unit_audit_trg
  BEFORE INSERT OR UPDATE ON org_unit
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- org_subtree(root) — поддерево org_unit начиная с root (включительно), рекурсивно по parent_id.
-- Зависит от таблицы org_unit, поэтому определяется здесь, а не в 004_helpers (roadmap относит
-- её к 004, но физически функция не может ссылаться на ещё не существующую таблицу — решение
-- зафиксировано в 004_helpers.sql комментарием).
--
-- РЕШЕНИЕ: SECURITY DEFINER + SET row_security = off. org_subtree() сама формирует политику RLS
-- (используется внутри USING/WITH CHECK org_unit_select и всех прочих доменных таблиц), поэтому
-- обычная SECURITY INVOKER-функция вызывала бы бесконечную рекурсию: чтение org_unit внутри
-- org_subtree() снова триггерит RLS-политику org_unit_select, которая снова вызывает
-- org_subtree() (stack depth limit exceeded — подтверждено эмпирически). SECURITY DEFINER
-- с row_security=off даёт функции обходить RLS при обходе дерева org_unit, оставаясь безопасной:
-- она лишь возвращает id организаций поддерева (не произвольные данные), а видимость самих строк
-- org_unit/прочих таблиц по-прежнему решает вызывающая политика через IN (SELECT id FROM ...).
CREATE OR REPLACE FUNCTION org_subtree(root_id uuid) RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET row_security = off
AS $$
  WITH RECURSIVE subtree AS (
    SELECT o.id FROM org_unit o WHERE o.id = root_id
    UNION ALL
    SELECT o.id FROM org_unit o JOIN subtree s ON o.parent_id = s.id
  )
  SELECT id FROM subtree;
$$;

-- Поддерево текущего пользователя (шорткат для RLS-политик всей схемы).
CREATE OR REPLACE FUNCTION current_org_subtree() RETURNS TABLE (id uuid)
LANGUAGE sql STABLE SECURITY DEFINER
SET row_security = off
AS $$
  SELECT id FROM org_subtree(current_org_unit_id());
$$;

ALTER TABLE org_unit ENABLE ROW LEVEL SECURITY;
ALTER TABLE org_unit FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS org_unit_select ON org_unit;
CREATE POLICY org_unit_select ON org_unit
  FOR SELECT
  USING (
    current_role_code() = 'admin' AND id IN (SELECT id FROM current_org_subtree())
    OR current_role_code() IN ('planner', 'dispatcher') AND id IN (SELECT id FROM current_org_subtree())
  );

DROP POLICY IF EXISTS org_unit_insert ON org_unit;
CREATE POLICY org_unit_insert ON org_unit
  FOR INSERT
  WITH CHECK (
    current_role_code() = 'admin'
    AND (parent_id IS NULL OR parent_id IN (SELECT id FROM current_org_subtree()))
  );

DROP POLICY IF EXISTS org_unit_update ON org_unit;
CREATE POLICY org_unit_update ON org_unit
  FOR UPDATE
  USING (current_role_code() = 'admin' AND id IN (SELECT id FROM current_org_subtree()))
  WITH CHECK (current_role_code() = 'admin' AND id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS org_unit_delete ON org_unit;
CREATE POLICY org_unit_delete ON org_unit
  FOR DELETE
  USING (current_role_code() = 'admin' AND id IN (SELECT id FROM current_org_subtree()));
