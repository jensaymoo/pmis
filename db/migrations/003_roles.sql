-- 003_roles — роли PostgreSQL: authenticator (служебная, вход через неё делает PostgREST),
-- anon (анонимная, только login), admin/planner/dispatcher (прикладные, соответствуют role_code).
-- Идемпотентно: DO-блок с проверкой pg_roles.
--
-- Модель (backend-access-and-roles.md): PostgREST подключается под authenticator (NOLOGIN
-- в смысле "нет самостоятельного пользовательского входа" — но JWT-роль должна уметь логиниться
-- для SET ROLE/переключения; в PostgREST authenticator обычно NOINHERIT и переключается на
-- прикладную роль через SET ROLE на основании claim "role" в JWT). Права авторизации выданы
-- прикладным ролям в 071_grants; здесь только сами роли.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin') THEN
    CREATE ROLE admin NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'planner') THEN
    CREATE ROLE planner NOLOGIN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dispatcher') THEN
    CREATE ROLE dispatcher NOLOGIN;
  END IF;
END $$;

-- authenticator должен уметь SET ROLE на любую из прикладных/анонимной ролей
GRANT anon TO authenticator;
GRANT admin TO authenticator;
GRANT planner TO authenticator;
GRANT dispatcher TO authenticator;

-- Пароль authenticator НЕ хардкодится здесь (секрет из окружения) — устанавливается
-- отдельным шагом развёртывания db/set-secrets.sh (ALTER ROLE authenticator PASSWORD ...
-- из $POSTGRES_PASSWORD), аналогично app.jwt_secret. До первого запуска set-secrets.sh
-- у роли нет пароля и подключение PGRST_DB_URI не работает — это ожидаемо на голой миграции.
