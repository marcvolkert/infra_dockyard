-- Bootstraps the anon role and the public API schema containing:
-- - a login RPC that re-exports auth.login for unauthenticated callers.
\set ON_ERROR_STOP on
BEGIN;
-- Public request entrypoint role. NOLOGIN because clients authenticate
-- with JWTs, not direct DB credentials.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT
        FROM
            pg_roles
        WHERE
            rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
END IF;
END
$$;
-- PostgREST connects as authenticator and SET ROLEs into JWT claims.
GRANT anon TO authenticator;
-- Keep exposed RPC surface in a dedicated schema.
CREATE SCHEMA IF NOT EXISTS api;
GRANT USAGE ON SCHEMA api TO anon;
-- Re-export auth.login in the exposed api schema so anonymous callers
-- can exchange credentials for a signed JWT.
CREATE OR REPLACE FUNCTION api.login (username text, PASSWORD TEXT)
    RETURNS auth.jwt_token
    AS $$
    SELECT
        auth.login (username, PASSWORD);
$$
LANGUAGE sql
SECURITY DEFINER;
-- Explicitly whitelist anon.
REVOKE ALL ON FUNCTION api.login (text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.login (text, text) TO anon;
COMMIT;
