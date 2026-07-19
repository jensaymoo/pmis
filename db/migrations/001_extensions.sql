-- 001_extensions — расширения СУБД: pgcrypto (bcrypt), pgjwt (подпись JWT)
-- Идемпотентно: IF NOT EXISTS.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pgjwt;
