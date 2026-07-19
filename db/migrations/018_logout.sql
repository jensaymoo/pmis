-- 018_logout — RPC logout(): SECURITY DEFINER, доступ app-ролям; инкремент token_version
-- текущего пользователя (инвалидация всех сессий). Возврат void → 204 No Content.

CREATE OR REPLACE FUNCTION logout() RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE users
  SET token_version = token_version + 1
  WHERE id = current_user_id();
END;
$$;

REVOKE ALL ON FUNCTION logout() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION logout() TO admin, planner, dispatcher;

-- ---------------------------------------------------------------------------
-- Инвалидация по token_version: JWT содержит claim "token_version" на момент выпуска
-- (см. 015_login.sql). PostgREST только проверяет подпись/exp, но не знает о logout —
-- поэтому используется db-pre-request хук (PGRST_DB_PRE_REQUEST), выполняемый ПОСЛЕ
-- переключения роли и ДО основного запроса на каждый HTTP-запрос: если claim.token_version
-- не совпадает с текущим users.token_version, запрос отклоняется 401.
-- Требует настройки PGRST_DB_PRE_REQUEST=public.check_token_version в docker-compose.yml.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_token_version() RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_claim_version integer;
  v_user_id uuid;
  v_db_version integer;
BEGIN
  v_user_id := current_user_id();

  -- Анонимные запросы (login) не несут user_id — пропускаем проверку.
  IF v_user_id IS NULL THEN
    RETURN;
  END IF;

  v_claim_version := (NULLIF(current_setting('request.jwt.claims', true), '')::json ->> 'token_version')::integer;

  SELECT token_version INTO v_db_version FROM users WHERE id = v_user_id;

  IF NOT FOUND OR v_db_version IS DISTINCT FROM v_claim_version THEN
    RAISE sqlstate 'PT401' USING message = 'Сессия отозвана, требуется повторный вход';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION check_token_version() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION check_token_version() TO admin, planner, dispatcher, anon;
