-- 012_roles — справочник ролей с привязкой к стартовому экрану (seed-only, без аудита).

CREATE TABLE IF NOT EXISTS roles (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            role_code NOT NULL UNIQUE,
  name            text NOT NULL,
  start_screen_id uuid NOT NULL REFERENCES screen (id)
);

CREATE INDEX IF NOT EXISTS roles_id_hash_idx ON roles USING hash (id);
CREATE INDEX IF NOT EXISTS roles_start_screen_id_hash_idx ON roles USING hash (start_screen_id);
