-- 016_me — RPC me(): профиль текущего пользователя + start_route. Доступ всем app-ролям.
-- current_user_id() читает claim из JWT текущего запроса (роль запроса уже переключена
-- PostgREST на planner/dispatcher/admin по claim "role" — SECURITY INVOKER достаточно,
-- но используем SECURITY DEFINER, т.к. users имеет RLS ограниченный org_subtree(), а own
-- row всегда входит в org_subtree(self) — поэтому обычный SELECT тоже сработал бы; тем не
-- менее SECURITY DEFINER гарантирует профиль всегда виден себе независимо от RLS-политик.

CREATE OR REPLACE FUNCTION me() RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_result json;
BEGIN
  SELECT json_build_object(
    'id', u.id,
    'email', u.email,
    'full_name', u.full_name,
    'role', u.role::text,
    'role_name', r.name,
    'org_unit_id', u.org_unit_id,
    'start_route', s.route
  ) INTO v_result
  FROM users u
  JOIN roles r ON r.code = u.role
  JOIN screen s ON s.id = r.start_screen_id
  WHERE u.id = current_user_id();

  IF v_result IS NULL THEN
    RAISE sqlstate 'PT401' USING message = 'Токен недействителен';
  END IF;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION me() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION me() TO admin, planner, dispatcher;
