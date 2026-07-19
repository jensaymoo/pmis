-- 002_enums — перечислимые типы для конечных множеств (backend-spec.md §5)
-- Идемпотентно: DO-блок с проверкой pg_type перед CREATE TYPE (CREATE TYPE не поддерживает IF NOT EXISTS).

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'role_code') THEN
    CREATE TYPE role_code AS ENUM ('admin', 'planner', 'dispatcher');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'record_status') THEN
    CREATE TYPE record_status AS ENUM ('created', 'enabled', 'disabled', 'deprecated');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'work_order_status') THEN
    CREATE TYPE work_order_status AS ENUM ('created', 'open', 'closed', 'canceled');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'section_kind') THEN
    CREATE TYPE section_kind AS ENUM ('area', 'linear');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_type') THEN
    CREATE TYPE task_type AS ENUM ('task', 'milestone');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'dependency_type') THEN
    CREATE TYPE dependency_type AS ENUM ('FS', 'SS', 'FF', 'SF');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'screen_code') THEN
    CREATE TYPE screen_code AS ENUM (
      'gantt', 'works', 'work_orders', 'users',
      'resources_personnel', 'resources_equipment', 'resources_materials', 'qty_unit'
    );
  END IF;
END $$;
