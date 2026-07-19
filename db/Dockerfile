FROM postgres:17

# Официального образа/пакета pgjwt нет — собираем из исходников поверх postgres:17.
# pgcrypto ставится штатным CREATE EXTENSION (входит в contrib), pgjwt — только сборкой.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        build-essential \
        postgresql-server-dev-17 \
    && git clone --depth 1 https://github.com/michelp/pgjwt.git /tmp/pgjwt \
    && make -C /tmp/pgjwt install \
    && rm -rf /tmp/pgjwt \
    && apt-get purge -y --auto-remove git build-essential postgresql-server-dev-17 \
    && rm -rf /var/lib/apt/lists/*
