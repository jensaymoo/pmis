-- 005_audit — единая переиспользуемая триггер-функция аудита (audit-spec.md §4).
-- Вешается только на доменные таблицы (§3a), НЕ на screen/menu_item/roles.
-- INSERT: created_at=updated_at=now(), created_by=updated_by=current_user_id(); значения клиента перетираются.
-- UPDATE: created_at/created_by сохраняются от старой строки; updated_at/updated_by обновляются.

CREATE OR REPLACE FUNCTION set_audit_fields() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at := now();
    NEW.created_by := current_user_id();
    NEW.updated_at := now();
    NEW.updated_by := current_user_id();
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.created_at := OLD.created_at;
    NEW.created_by := OLD.created_by;
    NEW.updated_at := now();
    NEW.updated_by := current_user_id();
  END IF;
  RETURN NEW;
END;
$$;
