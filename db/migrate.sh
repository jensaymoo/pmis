#!/usr/bin/env bash
# PMIS — раннер миграций. Применяет db/migrations/*.sql по порядку через psql,
# останавливается на первой ошибке (ON_ERROR_STOP=1). Без фреймворка миграций —
# проект принципиально без кастомного бэкенда, только версионируемый SQL.
#
# Использование:
#   ./db/migrate.sh                 — применить все миграции (в контейнере db)
#   ./db/migrate.sh 001 005         — применить диапазон миграций по префиксу номера
#   DB_HOST=localhost ./db/migrate.sh  — подключиться напрямую (не через docker compose exec)
#
# Переменные окружения читаются из .env в корне репозитория (если файл присутствует),
# либо должны быть заданы в окружении вызывающего процесса.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/migrations"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/.env"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:?POSTGRES_USER не задан (см. .env)}"
POSTGRES_DB="${POSTGRES_DB:?POSTGRES_DB не задан (см. .env)}"

USE_DOCKER="${USE_DOCKER:-1}"

run_psql_file() {
  local file="$1"
  if [ "$USE_DOCKER" = "1" ]; then
    docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T db \
      psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$file"
  else
    PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -v ON_ERROR_STOP=1 \
      -h "${DB_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$file"
  fi
}

shopt -s nullglob
files=("$MIGRATIONS_DIR"/*.sql)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "Нет файлов миграций в $MIGRATIONS_DIR" >&2
  exit 1
fi

# Опциональный диапазон по номеру префикса: migrate.sh 001 010
FROM="${1:-000}"
TO="${2:-999}"

applied=0
for f in "${files[@]}"; do
  base="$(basename "$f")"
  num="${base%%_*}"
  # Сравнение по номеру миграции (лексикографически, префиксы нулевые, работает корректно)
  if [[ "$num" < "$FROM" ]]; then
    continue
  fi
  if [[ "$num" > "$TO" ]]; then
    continue
  fi
  echo ">>> Применение $base"
  run_psql_file "$f"
  applied=$((applied + 1))
done

echo "Готово: применено $applied миграций."

# PostgREST кэширует схему при старте; NOTIFY pgrst,'reload schema' заставляет его перечитать
# каталог без рестарта контейнера (PostgREST слушает канал 'pgrst' по умолчанию с v10+).
if [ "$USE_DOCKER" = "1" ]; then
  docker compose -f "$REPO_ROOT/docker-compose.yml" exec -T db \
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "NOTIFY pgrst, 'reload schema';" > /dev/null
else
  PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -v ON_ERROR_STOP=1 \
    -h "${DB_HOST:-localhost}" -p "${POSTGRES_PORT:-5432}" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "NOTIFY pgrst, 'reload schema';" > /dev/null
fi
echo "PostgREST: отправлен сигнал перезагрузки схемы (NOTIFY pgrst, 'reload schema')."
