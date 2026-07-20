-- 073_org_unit_insert_scope_fix — устраняет разрыв между политиками INSERT и SELECT на org_unit.
--
-- Баг (найден при верификации Фазы 5, экран «Пользователи»): org_unit_insert (013_org_unit.sql)
-- разрешала parent_id IS NULL любому admin без проверки поддерева — администратор мог создать
-- несвязанную корневую организацию (INSERT проходил, 201 Created). Но org_unit_select показывает
-- только записи из current_org_subtree() — подтверждённо создатель НИКОГДА не видел только что
-- созданную запись (INSERT ... RETURNING тоже требовал бы SELECT-политику и уже честно отвечал
-- 403 "new row violates row-level security policy"; INSERT без RETURNING просто создавал
-- невидимую запись). access-and-roles-users.md §4.1: "Администратор строит и поддерживает эту
-- структуру в пределах своего поддерева" — создание не должно быть исключением.
--
-- Fix: parent_id обязателен и должен входить в current_org_subtree() (включает собственную
-- организацию администратора) — так же, как и для остальных доменных таблиц с org_unit_id.
-- Фронтенд (OrgUnitTree.vue) больше не отправляет parent_id: null для верхнего действия
-- «Создать» — использует auth.user.org_unit_id (родная организация администратора).

DROP POLICY IF EXISTS org_unit_insert ON org_unit;
CREATE POLICY org_unit_insert ON org_unit
  FOR INSERT
  WITH CHECK (
    current_role_code() = 'admin'
    AND parent_id IN (SELECT id FROM current_org_subtree())
  );
