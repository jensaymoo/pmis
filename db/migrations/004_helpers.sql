-- 004_helpers — вспомогательные функции контекста текущего пользователя (из JWT-claims).
-- org_subtree(uuid) объявлена в 013_org_unit.sql (зависит от таблицы org_unit, которая ещё
-- не существует на этом шаге) — решение зафиксировано здесь, т.к. roadmap перечисляет
-- org_subtree в 004, но физически функция не может быть создана раньше своей таблицы.
-- Идемпотентно: CREATE OR REPLACE.

-- Идентификатор текущего пользователя из claim "user_id" текущего JWT (request.jwt.claims).
-- Возвращает NULL, если claim отсутствует (например, сид-миграции, вызовы вне HTTP-запроса).
CREATE OR REPLACE FUNCTION current_user_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT (NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'user_id')::uuid;
$$;

-- Организация текущего пользователя из claim "org_unit_id".
CREATE OR REPLACE FUNCTION current_org_unit_id() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  SELECT (NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'org_unit_id')::uuid;
$$;

-- Код роли текущего пользователя из claim "role".
CREATE OR REPLACE FUNCTION current_role_code() RETURNS role_code
LANGUAGE sql STABLE
AS $$
  SELECT (NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'role')::role_code;
$$;

