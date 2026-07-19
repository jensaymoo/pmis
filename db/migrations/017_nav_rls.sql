-- 017_nav_rls — RLS на menu_item: фильтр по role_code из JWT-claim текущего токена.
-- screen и roles остаются публично читаемыми всем app-ролям (без RLS-фильтрации — seed-only,
-- см. auth-and-navigation-api.md GET /screen, GET /roles).

ALTER TABLE menu_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_item FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS menu_item_select ON menu_item;
CREATE POLICY menu_item_select ON menu_item
  FOR SELECT
  USING (role_code = current_role_code());

-- menu_item/screen/roles — seed-only, изменяются только миграциями (см. 072_seed);
-- никаких INSERT/UPDATE/DELETE политик для прикладных ролей не создаём (запрещено по умолчанию
-- под RLS без соответствующей политики).
