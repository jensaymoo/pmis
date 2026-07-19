-- 018a_change_password — RPC change_password(old_password, new_password): bcrypt-проверка
-- старого пароля, SECURITY DEFINER, доступ app-ролям; инкремент token_version (инвалидация
-- прочих сессий). Правила из access-and-roles-api.md: локаут (423), неверный старый пароль
-- (401), совпадение нового со старым (400), мин. длина 8 (400). Сброс failed_attempts/locked_until.

CREATE OR REPLACE FUNCTION change_password(old_password text, new_password text) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user users%ROWTYPE;
BEGIN
  SELECT * INTO v_user FROM users WHERE id = current_user_id();

  IF NOT FOUND THEN
    RAISE sqlstate 'PT401' USING message = 'Токен недействителен';
  END IF;

  IF v_user.locked_until IS NOT NULL AND v_user.locked_until > now() THEN
    RAISE sqlstate 'PT423' USING message = format('Учётная запись заблокирована до %s', v_user.locked_until);
  END IF;

  IF v_user.password IS NULL OR crypt(old_password, v_user.password) <> v_user.password THEN
    RAISE sqlstate 'PT401' USING message = 'Текущий пароль неверен';
  END IF;

  IF length(new_password) < 8 THEN
    RAISE sqlstate 'PT400' USING message = 'Новый пароль должен содержать не менее 8 символов';
  END IF;

  IF crypt(new_password, v_user.password) = v_user.password THEN
    RAISE sqlstate 'PT400' USING message = 'Новый пароль не может совпадать с текущим';
  END IF;

  UPDATE users
  SET password = new_password, -- перехешируется триггером users_hash_password_trg
      failed_attempts = 0,
      locked_until = NULL,
      token_version = token_version + 1
  WHERE id = v_user.id;
END;
$$;

REVOKE ALL ON FUNCTION change_password(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION change_password(text, text) TO admin, planner, dispatcher;
