-- 010_screen — каталог экранов системы (seed-only, без аудита и record_status).

CREATE TABLE IF NOT EXISTS screen (
  id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code  screen_code NOT NULL UNIQUE,
  route text NOT NULL
);

CREATE INDEX IF NOT EXISTS screen_id_hash_idx ON screen USING hash (id);
