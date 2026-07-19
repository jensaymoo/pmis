-- 006_jwt_secret — GUC app.jwt_secret: НЕ хардкодится в миграции (backend-spec.md §6).
-- Реальная установка значения — отдельный шаг развёртывания из окружения:
--   db/set-secrets.sh (читает PGRST_JWT_SECRET из .env и делает
--   ALTER DATABASE ... SET app.jwt_secret = '...').
--
-- Здесь только гарантируем, что параметр существует с безопасным значением по умолчанию
-- на уровне custom GUC namespace "app", чтобы current_setting('app.jwt_secret', true) не падал
-- до того, как set-secrets.sh отработает (например, при первом psql-подключении до deploy-шага).
-- Значение-плейсхолдер ниже — НЕ секрет и не используется в проде; set-secrets.sh обязателен
-- на каждом развёртывании и перезаписывает его реальным секретом из окружения.

DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET app.jwt_secret = %L', current_database(), 'CHANGE_ME_VIA_db/set-secrets.sh');
END $$;

-- Требуется новое подключение для применения ALTER DATABASE ... SET (текущая сессия миграции
-- этого не увидит, что нормально — set-secrets.sh запускается отдельным шагом после миграций).
