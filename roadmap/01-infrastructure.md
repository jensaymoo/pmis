# Фаза 1 — Инфраструктура

> Всё запускается, ничего не делает.

## Документы

| Документ | Что берём |
|----------|-----------|
| `pmis.wiki/docs/backend-spec.md` §1–2 | Стек, PostgREST, Docker, pgjwt |
| `pmis.wiki/docs/frontend-spec.md` §1–3 | Vue 3, Vite, пакеты, proxy |

## Что делаем

- Docker Compose: PostgreSQL 17 + PostgREST 14
- `db/Dockerfile` с расширением pgjwt
- `.env.example` со всеми переменными
- Скаффолдинг фронтенда: `package.json`, `vite.config.js`, `index.html`
- Пустые `main.js`, `App.vue`, `main.css` (Tailwind)
- Proxy `/api` → PostgREST в Vite
- ESLint: `eslint.config.js` (flat config, eslint-plugin-vue, @eslint/js, globals), скрипт `"lint": "eslint ."` в `package.json`

## Готово когда

- `docker compose up` — PostgreSQL и PostgREST стартуют без ошибок
- `npm run dev` — пустая страница на `:5173`
- `/api/` отвечает (пусть пока 404 — схемы нет)

**Оценка:** 2–3 дня
