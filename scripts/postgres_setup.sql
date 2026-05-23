-- =============================================================================
-- PostgreSQL Production Setup Script
-- =============================================================================
-- PURPOSE : Create database, schema, flyway migration user, and app runtime user
--           with least-privilege access controls.
-- USAGE   : Run via setup_db.sh (reads credentials from .envrc)
--           OR manually: psql -U postgres \
--                          -v db_name=myapp \
--                          -v schema_name=app_auth \
--                          -v flyway_user=flyway_user \
--                          -v flyway_password=secret \
--                          -v app_user=app_user \
--                          -v app_password=secret \
--                          -f postgres_setup.sql
-- =============================================================================


-- =============================================================================
-- SECTION 1: CREATE DATABASE
-- =============================================================================

CREATE DATABASE :db_name
    ENCODING 'UTF8'
    LC_COLLATE = 'en_US.UTF-8'
    LC_CTYPE   = 'en_US.UTF-8'
    TEMPLATE   = template0;

-- Connect to the new database before running the rest
\c :db_name


-- =============================================================================
-- SECTION 2: CREATE USERS
-- =============================================================================

-- Flyway migration user — runs DDL (CREATE, ALTER, DROP)
CREATE USER :flyway_user WITH
    PASSWORD :'flyway_password'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    LOGIN;

-- App runtime user — runs DML only (SELECT, INSERT, UPDATE, DELETE)
CREATE USER :app_user WITH
    PASSWORD :'app_password'
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    LOGIN;


-- =============================================================================
-- SECTION 3: DATABASE-LEVEL PRIVILEGES
-- =============================================================================

-- Revoke default public access
REVOKE ALL ON DATABASE :db_name FROM PUBLIC;

-- Both users need to connect
GRANT CONNECT ON DATABASE :db_name TO :flyway_user;
GRANT CONNECT ON DATABASE :db_name TO :app_user;

-- Only flyway needs to create schemas
GRANT CREATE ON DATABASE :db_name TO :flyway_user;


-- =============================================================================
-- SECTION 4: CREATE SCHEMA
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS :schema_name;

-- Flyway owns the schema
ALTER SCHEMA :schema_name OWNER TO :flyway_user;


-- =============================================================================
-- SECTION 5: SCHEMA-LEVEL PRIVILEGES
-- =============================================================================

-- Flyway — full control over the schema
GRANT ALL ON SCHEMA :schema_name TO :flyway_user;

-- App user — can use the schema but not modify it
GRANT USAGE ON SCHEMA :schema_name TO :app_user;
REVOKE CREATE ON SCHEMA :schema_name FROM :app_user;


-- =============================================================================
-- SECTION 6: TABLE-LEVEL PRIVILEGES (existing tables)
-- =============================================================================

-- Flyway — full DDL + DML on all current tables
GRANT ALL ON ALL TABLES IN SCHEMA :schema_name TO :flyway_user;

-- App user — DML only, no DDL
GRANT SELECT, INSERT, UPDATE, DELETE
    ON ALL TABLES IN SCHEMA :schema_name TO :app_user;

-- Sequences (required for SERIAL / BIGSERIAL / IDENTITY columns)
GRANT ALL ON ALL SEQUENCES IN SCHEMA :schema_name TO :flyway_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :schema_name TO :app_user;


-- =============================================================================
-- SECTION 7: DEFAULT PRIVILEGES (future tables created by flyway)
-- =============================================================================
-- CRITICAL: Without this, app_user won't have access to tables created
--           by future Flyway migrations.

ALTER DEFAULT PRIVILEGES FOR USER :flyway_user IN SCHEMA :schema_name
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :app_user;

ALTER DEFAULT PRIVILEGES FOR USER :flyway_user IN SCHEMA :schema_name
    GRANT USAGE, SELECT ON SEQUENCES TO :app_user;

-- Flyway keeps full access to its own future tables
ALTER DEFAULT PRIVILEGES FOR USER :flyway_user IN SCHEMA :schema_name
    GRANT ALL ON TABLES TO :flyway_user;

ALTER DEFAULT PRIVILEGES FOR USER :flyway_user IN SCHEMA :schema_name
    GRANT ALL ON SEQUENCES TO :flyway_user;


-- =============================================================================
-- SECTION 8: LOCK DOWN PUBLIC SCHEMA (security best practice)
-- =============================================================================

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;


-- =============================================================================
-- SECTION 9: VERIFY
-- =============================================================================

SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin
FROM pg_roles
WHERE rolname IN (:'flyway_user', :'app_user');

\dn+

-- =============================================================================
-- SECTION 10: application.yml reference
-- =============================================================================
--
-- spring:
--   datasource:
--     url: jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
--     username: ${DB_APP_USER}
--     password: ${DB_APP_PASSWORD}
--
--   flyway:
--     url: jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
--     user: ${DB_FLYWAY_USER}
--     password: ${DB_FLYWAY_PASSWORD}
--     schemas: ${DB_SCHEMA}
--     locations: classpath:db/migration
--     enabled: true
--
--   jpa:
--     hibernate:
--       ddl-auto: validate
--     properties:
--       hibernate:
--         default_schema: ${DB_SCHEMA}
--
-- =============================================================================
-- END OF SCRIPT
-- =============================================================================
