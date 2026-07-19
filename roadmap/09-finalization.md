# Фаза 9 — Финализация

> Интеграционный тест, продакшн-деплой, полировка.

## Документы

| Документ | Что берём |
|----------|-----------|
| Все `pmis.wiki/docs/*-screen`, `pmis.wiki/docs/auth-and-navigation-*`, `pmis.wiki/docs/resources-*` | Секции Verification каждого экрана |
| `pmis.wiki/docs/access-and-roles-business.md` | Сквозной поток: админ → планировщик → диспетчер |
| `pmis.wiki/docs/frontend-spec.md` §6 | Жизненный цикл сессии (основа для httpOnly cookie на проде) |
| `CLAUDE.md` (раздел «Безопасность») | JWT в httpOnly cookie, reverse-proxy подставляет `Authorization: Bearer` |

## 9.1 — Сквозной тест

1. Админ создаёт org_unit → создаёт пользователя в нём
2. Планировщик строит WBS + участки + ресурсный план + распределяет дневной план по дням
3. Диспетчер создаёт наряд → закрывает с фактом + ресурсами
4. Экран «Работы» показывает корректный план/факт/отклонение
5. RLS: пользователь дочерней зоны не видит данные соседней
6. Анти-эскалация: админ не может повысить себя
7. Деактивация пользователя/ресурса с открытыми ссылками → блокировка
8. Конкурентные закрытия одной работы → корректная сумма

## 9.2 — Продакшн

- `nginx/nginx.conf` — reverse proxy: статика, `/api` → PostgREST, httpOnly cookie → `Authorization` header
- `docker-compose.yml` — nginx, health checks, restart policies
- `.env.example` — финальная версия
- CI pipeline — lint, миграции на тестовой БД, build фронтенда

**Оценка:** 4–6 дней
