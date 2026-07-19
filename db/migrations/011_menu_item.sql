-- 011_menu_item — пункты меню, привязка к роли, вложенность, сортировка (seed-only, без аудита).

CREATE TABLE IF NOT EXISTS menu_item (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  role_code  role_code NOT NULL,
  parent_id  uuid REFERENCES menu_item (id),
  screen_id  uuid REFERENCES screen (id),
  label      text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  icon       text
);

CREATE INDEX IF NOT EXISTS menu_item_id_hash_idx ON menu_item USING hash (id);
CREATE INDEX IF NOT EXISTS menu_item_parent_id_hash_idx ON menu_item USING hash (parent_id);
CREATE INDEX IF NOT EXISTS menu_item_screen_id_hash_idx ON menu_item USING hash (screen_id);

-- Максимальная глубина вложенности меню — 5 уровней. Реализовано рекурсивной функцией
-- (CHECK constraint не может быть рекурсивным сам по себе), вызываемой из триггера.
CREATE OR REPLACE FUNCTION menu_item_depth(p_id uuid) RETURNS integer
LANGUAGE sql STABLE
AS $$
  WITH RECURSIVE chain AS (
    SELECT id, parent_id, 1 AS depth FROM menu_item WHERE id = p_id
    UNION ALL
    SELECT m.id, m.parent_id, c.depth + 1
    FROM menu_item m JOIN chain c ON m.id = c.parent_id
  )
  SELECT max(depth) FROM chain;
$$;

CREATE OR REPLACE FUNCTION menu_item_check_depth() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_depth integer := 1;
  v_parent uuid := NEW.parent_id;
BEGIN
  WHILE v_parent IS NOT NULL LOOP
    v_depth := v_depth + 1;
    IF v_depth > 5 THEN
      RAISE EXCEPTION 'menu_item: превышена максимальная глубина вложенности (5)';
    END IF;
    SELECT parent_id INTO v_parent FROM menu_item WHERE id = v_parent;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS menu_item_depth_trg ON menu_item;
CREATE TRIGGER menu_item_depth_trg
  BEFORE INSERT OR UPDATE OF parent_id ON menu_item
  FOR EACH ROW EXECUTE FUNCTION menu_item_check_depth();
