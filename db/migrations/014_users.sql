-- 014_users — пользователи + аудит + RLS + анти-эскалация + record_status lifecycle +
-- token_version (инвалидация сессий) + bcrypt-хеширование пароля + блокировка после
-- неудачных попыток + защита "последнего пользователя роли в зоне".

CREATE TABLE IF NOT EXISTS users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email           text NOT NULL UNIQUE,
  password        text NOT NULL,
  full_name       text NOT NULL,
  role            role_code NOT NULL,
  org_unit_id     uuid NOT NULL REFERENCES org_unit (id),
  status          record_status NOT NULL DEFAULT 'created',
  failed_attempts integer DEFAULT 0,
  locked_until    timestamptz,
  token_version   integer NOT NULL DEFAULT 0,
  created_at      timestamptz,
  created_by      uuid,
  updated_at      timestamptz,
  updated_by      uuid
);

CREATE INDEX IF NOT EXISTS users_id_hash_idx ON users USING hash (id);
CREATE INDEX IF NOT EXISTS users_org_unit_id_hash_idx ON users USING hash (org_unit_id);
CREATE UNIQUE INDEX IF NOT EXISTS users_email_btree_idx ON users USING btree (email);

-- FK от org_unit.created_by/updated_by и qty_unit.* etc к users.id ссылаются вперёд;
-- добавляем их сейчас, раз users уже существует. DO-блок с проверкой pg_constraint —
-- ALTER TABLE ADD CONSTRAINT не поддерживает IF NOT EXISTS.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'org_unit_created_by_fkey') THEN
    ALTER TABLE org_unit ADD CONSTRAINT org_unit_created_by_fkey FOREIGN KEY (created_by) REFERENCES users (id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'org_unit_updated_by_fkey') THEN
    ALTER TABLE org_unit ADD CONSTRAINT org_unit_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES users (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS org_unit_created_by_hash_idx ON org_unit USING hash (created_by);
CREATE INDEX IF NOT EXISTS org_unit_updated_by_hash_idx ON org_unit USING hash (updated_by);

-- ---------------------------------------------------------------------------
-- Триггер 1: подстановка org_unit_id по умолчанию = организация текущего пользователя.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION users_default_org_unit() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.org_unit_id IS NULL THEN
    NEW.org_unit_id := current_org_unit_id();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_default_org_unit_trg ON users;
CREATE TRIGGER users_default_org_unit_trg
  BEFORE INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION users_default_org_unit();

-- ---------------------------------------------------------------------------
-- Триггер 2: хеширование пароля (bcrypt) при INSERT/UPDATE, если password изменился
-- и ещё не является bcrypt-хешем (идемпотентность против повторного хеширования).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION users_hash_password() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.password IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.password IS DISTINCT FROM OLD.password)
     -- bcrypt-хеши начинаются с $2a$/$2b$/$2y$ и имеют длину 60; если уже похоже на хеш,
     -- не хешируем повторно (например, значение пришло из другого триггера/сида как хеш).
     AND NOT (NEW.password ~ '^\$2[aby]\$[0-9]{2}\$.{53}$')
  THEN
    NEW.password := crypt(NEW.password, gen_salt('bf'));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_hash_password_trg ON users;
CREATE TRIGGER users_hash_password_trg
  BEFORE INSERT OR UPDATE OF password ON users
  FOR EACH ROW EXECUTE FUNCTION users_hash_password();

-- ---------------------------------------------------------------------------
-- Триггер 3: защита "последнего пользователя роли в зоне" на UPDATE status (переход из
-- enabled в не-enabled) и на DELETE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION users_guard_last_role_in_org() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_others_enabled integer;
BEGIN
  SELECT count(*) INTO v_others_enabled
  FROM users
  WHERE role = OLD.role
    AND org_unit_id = OLD.org_unit_id
    AND status = 'enabled'
    AND id <> OLD.id;

  IF TG_OP = 'DELETE' THEN
    IF OLD.status = 'enabled' AND v_others_enabled < 1 THEN
      RAISE EXCEPTION 'в этой организации нет других пользователей данной роли';
    END IF;
    RETURN OLD;
  END IF;

  -- UPDATE: блокируем только переходы OUT of enabled (деактивация/мягкое удаление)
  IF OLD.status = 'enabled' AND NEW.status IS DISTINCT FROM 'enabled' AND v_others_enabled < 1 THEN
    RAISE EXCEPTION 'в этой организации нет других пользователей данной роли';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_guard_last_role_upd_trg ON users;
CREATE TRIGGER users_guard_last_role_upd_trg
  BEFORE UPDATE OF status ON users
  FOR EACH ROW EXECUTE FUNCTION users_guard_last_role_in_org();

DROP TRIGGER IF EXISTS users_guard_last_role_del_trg ON users;
CREATE TRIGGER users_guard_last_role_del_trg
  BEFORE DELETE ON users
  FOR EACH ROW EXECUTE FUNCTION users_guard_last_role_in_org();

-- ---------------------------------------------------------------------------
-- Аудит-триггер (created_at/created_by/updated_at/updated_by).
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS users_audit_trg ON users;
CREATE TRIGGER users_audit_trg
  BEFORE INSERT OR UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_audit_fields();

-- ---------------------------------------------------------------------------
-- RLS: admin — CRUD в org_subtree() с анти-эскалацией; planner/dispatcher — read-only
-- в своём org_subtree().
-- ---------------------------------------------------------------------------
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE users FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS users_select ON users;
CREATE POLICY users_select ON users
  FOR SELECT
  USING (org_unit_id IN (SELECT id FROM current_org_subtree()));

DROP POLICY IF EXISTS users_insert ON users;
CREATE POLICY users_insert ON users
  FOR INSERT
  WITH CHECK (
    current_role_code() = 'admin'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  );

-- Анти-эскалация: администратор не может изменить собственную role/org_unit_id;
-- в остальном CRUD ограничен своим поддеревом.
-- РЕШЕНИЕ: сравнение идёт с current_role_code()/current_org_unit_id() (значения из JWT-claim
-- текущего токена), а НЕ с подзапросом "SELECT role FROM users WHERE id = current_user_id()" —
-- такой подзапрос на самой таблице users внутри её же RLS-политики вызывает
-- "infinite recursion detected in policy for relation users" (подтверждено эмпирически: политика
-- на users, читающая users, заново запускает саму себя). Claim'ы из токена уже надёжно содержат
-- текущие role/org_unit_id пользователя на момент выпуска токена — этого достаточно для проверки
-- "не совпадает с новым значением", т.к. попытка эскалации всегда сравнивается с ЗАЯВЛЕННЫМИ (не
-- изменившимися за время сессии) правами, а не с потенциально уже изменёнными кем-то другим.
DROP POLICY IF EXISTS users_update ON users;
CREATE POLICY users_update ON users
  FOR UPDATE
  USING (
    current_role_code() = 'admin'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
  )
  WITH CHECK (
    current_role_code() = 'admin'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
    AND (
      id <> current_user_id()
      OR (role = current_role_code() AND org_unit_id = current_org_unit_id())
    )
  );

DROP POLICY IF EXISTS users_delete ON users;
CREATE POLICY users_delete ON users
  FOR DELETE
  USING (
    current_role_code() = 'admin'
    AND org_unit_id IN (SELECT id FROM current_org_subtree())
    AND id <> current_user_id()
  );
