-- 015_login — RPC login(email, password): bcrypt-проверка, JWT (pgjwt), SECURITY DEFINER,
-- доступ anon. Только enabled-пользователи. failed_attempts/locked_until с блокировкой на
-- 5+ попыток на 15 минут (423 Locked). При успехе — сброс счётчика.
--
-- HTTP-статус кастомизируется через PostgREST-конвенцию SQLSTATE класса 'PTxyz' —
-- RAISE sqlstate 'PT401'/'PT423' напрямую транслируется PostgREST в соответствующий HTTP-код
-- (см. https://docs.postgrest.org/en/v14/references/errors.html — RAISE errors with HTTP Status Codes).
--
-- РЕШЕНИЕ (важно): PostgREST выполняет каждый HTTP-запрос в одной транзакции. RAISE EXCEPTION
-- откатывает ВСЕ эффекты текущей функции, включая UPDATE failed_attempts, сделанный до RAISE —
-- значит "в лоб" (UPDATE, затем RAISE) счётчик неудачных попыток никогда бы не сохранялся.
-- Чтобы инкремент failed_attempts/установка locked_until пережили последующий RAISE, используется
-- dblink с автономным подключением к той же базе (localhost, тот же кластер) — короткая
-- самостоятельная транзакция, которая коммитится независимо от исхода внешней транзакции login().
-- Это единственный надёжный способ "автономной транзакции" в чистом PL/pgSQL без внешнего кода.

CREATE EXTENSION IF NOT EXISTS dblink;

-- Автономная фиксация неудачной попытки входа (инкремент failed_attempts, блокировка при 5+).
-- SECURITY DEFINER, вызывается только изнутри login() — не выставляется наружу через GRANT anon.
-- Использует одноразовое (не именованное) dblink-соединение через dblink_exec(conninfo, sql) —
-- открывается и закрывается внутри вызова, поэтому конфликтов имён соединений при конкурентных
-- запросах не возникает (в отличие от именованных соединений dblink_connect('name', ...)).
CREATE OR REPLACE FUNCTION record_failed_login(p_user_id uuid) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_conninfo text := format('dbname=%s user=%s', current_database(), current_user);
BEGIN
  PERFORM dblink_exec(
    v_conninfo,
    format(
      $sql$
        UPDATE users
        SET failed_attempts = COALESCE(failed_attempts, 0) + 1,
            locked_until = CASE
              WHEN COALESCE(failed_attempts, 0) + 1 >= 5 THEN now() + interval '15 minutes'
              ELSE locked_until
            END
        WHERE id = %L
      $sql$,
      p_user_id
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION record_failed_login(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION login(email text, password text) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user users%ROWTYPE;
  v_secret text;
  v_token text;
BEGIN
  SELECT * INTO v_user FROM users u WHERE u.email = login.email;

  IF NOT FOUND THEN
    RAISE sqlstate 'PT401' USING message = 'Неверный email или пароль';
  END IF;

  IF v_user.status <> 'enabled' THEN
    RAISE sqlstate 'PT401' USING message = 'Учётная запись отключена';
  END IF;

  IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN
    RAISE sqlstate 'PT423' USING message = format('Учётная запись заблокирована до %s', v_user.locked_until);
  END IF;

  IF v_user.password IS NULL OR crypt(login.password, v_user.password) <> v_user.password THEN
    -- Неудачная попытка: инкремент failed_attempts в автономной транзакции (переживает RAISE ниже).
    PERFORM record_failed_login(v_user.id);
    RAISE sqlstate 'PT401' USING message = 'Неверный email или пароль';
  END IF;

  -- Успешный вход: сброс счётчика и блокировки (в основной транзакции — RAISE дальше не идёт).
  UPDATE users
  SET failed_attempts = 0, locked_until = NULL
  WHERE id = v_user.id;

  v_secret := current_setting('app.jwt_secret', true);

  SELECT sign(
    json_build_object(
      'role', v_user.role::text,
      'user_id', v_user.id,
      'org_unit_id', v_user.org_unit_id,
      'token_version', v_user.token_version,
      'exp', extract(epoch FROM (now() + interval '8 hours'))::integer
    ),
    v_secret
  ) INTO v_token;

  RETURN json_build_object('token', v_token);
END;
$$;

REVOKE ALL ON FUNCTION login(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION login(text, text) TO anon;
