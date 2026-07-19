#!/usr/bin/env bash
# PMIS — установка секретов уровня БД (GUC), не хранящихся в миграциях.
# app.jwt_secret используется login()/pgjwt для подписи и проверки JWT.
# Значение берётся из окружения (.env: PGRST_JWT_SECRET), а не хардкодится в SQL.
#
# Использование: ./db/set-secrets.sh
# Идемпотентно: повторный запуск безопасен (ALTER DATABASE ... SET перезаписывает значение).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:?POSTGRES_USER не задан (см. .env)}"
POSTGRES_DB="${POSTGRES_DB:?POSTGRES_DB не задан (см. .env)}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD не задан (см. .env)}"
PGRST_JWT_SECRET="${PGRST_JWT_SECRET:?PGRST_JWT_SECRET не задан (см. .env)}"

USE_DOCKER="${USE_DOCKER:-1}"

SQL="ALTER DATABASE \"$POSTGRES_DB\" SET app.jwt_secret = '$PGRST_JWT_SECRET';
ALTER ROLE authenticator PASSWORD '$POSTGRES_PASSWORD';"

if [ "$USE_DOCKER" = "1" ]; then
  docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T db \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$SQL"
else
  PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -v ON_ERROR_STOP=1 \
    -h "${DB_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$SQL"
fi

echo "app.jwt_secret установлен на уровне базы данных $POSTGRES_DB."
echo "Пароль роли authenticator синхронизирован с \$POSTGRES_PASSWORD (используется PGRST_DB_URI)."
echo "ВНИМАНИЕ: требуется переподключение сессий (или reload) для применения; новые backend-соединения увидят GUC сразу."
echo "ВНИМАНИЕ: перезапустите сервис postgrest (docker compose restart postgrest), чтобы он переподключился с новым паролем."
