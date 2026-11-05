-- ============================================================
-- Логическое шардирование как у Instagram
-- Архитектура:
-- Клиент → Приложение/Proxy → shard_map → physical_host + database
-- ============================================================

-- Очистка
DROP SCHEMA IF EXISTS shard_meta CASCADE;
DROP SCHEMA IF EXISTS shard_0000 CASCADE;
DROP SCHEMA IF EXISTS shard_0001 CASCADE;
DROP SCHEMA IF EXISTS shard_0002 CASCADE;
DROP SCHEMA IF EXISTS shard_0003 CASCADE;

-- ------------------------------------------------------------
-- 1. Мета-схема + таблица маршрутизации
-- ------------------------------------------------------------
CREATE SCHEMA shard_meta;

CREATE TABLE shard_meta.shard_map (
    logical_shard_id   INTEGER PRIMARY KEY,
    physical_host      TEXT NOT NULL,          -- например 'pg-01.prod.internal'
    physical_port      INTEGER NOT NULL DEFAULT 5432,
    database_name      TEXT NOT NULL,          -- имя базы на физическом сервере
    schema_name        TEXT,                   -- опционально (если используем схемы)
    is_active          BOOLEAN NOT NULL DEFAULT true,
    weight             INTEGER NOT NULL DEFAULT 100
);

-- Пример заполнения (в реальности хосты разные)
INSERT INTO shard_meta.shard_map 
    (logical_shard_id, physical_host, database_name, schema_name) 
VALUES
(0, 'localhost', 'postgres', 'shard_0000'),
(1, 'localhost', 'postgres', 'shard_0001'),
(2, 'localhost', 'postgres', 'shard_0002'),
(3, 'localhost', 'postgres', 'shard_0003');

-- ------------------------------------------------------------
-- 2. Функции маршрутизации
-- ------------------------------------------------------------

-- Определяем logical_shard по user_id
CREATE OR REPLACE FUNCTION shard_meta.get_logical_shard(user_id BIGINT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT abs(hashtext(user_id::text)) % 4;
$$;

-- Полная информация о шарде (то, что нужно приложению/прокси)
CREATE OR REPLACE FUNCTION shard_meta.get_shard_info(user_id BIGINT)
RETURNS TABLE (
    logical_shard_id  INTEGER,
    physical_host     TEXT,
    physical_port     INTEGER,
    database_name     TEXT,
    schema_name       TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        m.logical_shard_id,
        m.physical_host,
        m.physical_port,
        m.database_name,
        m.schema_name
    FROM shard_meta.shard_map m
    WHERE m.logical_shard_id = shard_meta.get_logical_shard(user_id)
      AND m.is_active = true;
$$;

-- ------------------------------------------------------------
-- 3. Создаём одинаковые таблицы во всех шардах
-- ------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT schema_name FROM shard_meta.shard_map LOOP
        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', r.schema_name);

        EXECUTE format('
            CREATE TABLE %I.users (
                id          BIGINT PRIMARY KEY,
                username    TEXT NOT NULL UNIQUE,
                email       TEXT,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            )', r.schema_name);

        EXECUTE format('
            CREATE TABLE %I.media (
                id          BIGINT PRIMARY KEY,
                user_id     BIGINT NOT NULL,
                caption     TEXT,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            )', r.schema_name);

        EXECUTE format('
            CREATE TABLE %I.follows (
                follower_id BIGINT NOT NULL,
                followee_id BIGINT NOT NULL,
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (follower_id, followee_id)
            )', r.schema_name);

        EXECUTE format('CREATE INDEX ON %I.media (user_id, created_at DESC)', r.schema_name);
        EXECUTE format('CREATE INDEX ON %I.follows (followee_id)', r.schema_name);
    END LOOP;
END $$;

-- ------------------------------------------------------------
-- 4. Функции записи (приложение обычно делает это само)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION shard_meta.insert_user(
    p_id BIGINT,
    p_username TEXT,
    p_email TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    info RECORD;
BEGIN
    SELECT * INTO info FROM shard_meta.get_shard_info(p_id);
    
    EXECUTE format(
        'INSERT INTO %I.users (id, username, email) VALUES ($1, $2, $3)',
        info.schema_name
    ) USING p_id, p_username, p_email;
END;
$$;

CREATE OR REPLACE FUNCTION shard_meta.insert_media(
    p_id BIGINT,
    p_user_id BIGINT,
    p_caption TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    info RECORD;
BEGIN
    SELECT * INTO info FROM shard_meta.get_shard_info(p_user_id);
    
    EXECUTE format(
        'INSERT INTO %I.media (id, user_id, caption) VALUES ($1, $2, $3)',
        info.schema_name
    ) USING p_id, p_user_id, p_caption;
END;
$$;

-- ------------------------------------------------------------
-- 5. Функции чтения
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION shard_meta.get_user(p_id BIGINT)
RETURNS TABLE (id BIGINT, username TEXT, email TEXT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    info RECORD;
BEGIN
    SELECT * INTO info FROM shard_meta.get_shard_info(p_id);
    
    RETURN QUERY EXECUTE format(
        'SELECT id, username, email, created_at FROM %I.users WHERE id = $1',
        info.schema_name
    ) USING p_id;
END;
$$;

CREATE OR REPLACE FUNCTION shard_meta.get_user_media(p_user_id BIGINT)
RETURNS TABLE (id BIGINT, user_id BIGINT, caption TEXT, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
AS $$
DECLARE
    info RECORD;
BEGIN
    SELECT * INTO info FROM shard_meta.get_shard_info(p_user_id);
    
    RETURN QUERY EXECUTE format(
        'SELECT id, user_id, caption, created_at 
         FROM %I.media 
         WHERE user_id = $1 
         ORDER BY created_at DESC',
        info.schema_name
    ) USING p_user_id;
END;
$$;

-- ------------------------------------------------------------
-- 6. Демонстрация
-- ------------------------------------------------------------
SELECT shard_meta.insert_user(1001, 'alice', 'alice@example.com');
SELECT shard_meta.insert_user(1002, 'bob',   'bob@example.com');
SELECT shard_meta.insert_user(1003, 'carol', 'carol@example.com');
SELECT shard_meta.insert_user(1004, 'dave',  'dave@example.com');
SELECT shard_meta.insert_user(1005, 'eve',   'eve@example.com');

SELECT shard_meta.insert_media(5001, 1001, 'Hello from Alice!');
SELECT shard_meta.insert_media(5002, 1001, 'Another post');
SELECT shard_meta.insert_media(5003, 1002, 'Bob was here');
SELECT shard_meta.insert_media(5004, 1003, 'Carol photo');

-- ------------------------------------------------------------
-- 7. Как выглядит маршрутизация
-- ------------------------------------------------------------
SELECT * FROM shard_meta.get_shard_info(1001);
SELECT * FROM shard_meta.get_shard_info(1002);
SELECT * FROM shard_meta.get_shard_info(1003);
SELECT * FROM shard_meta.get_shard_info(1004);
SELECT * FROM shard_meta.get_shard_info(1005);
