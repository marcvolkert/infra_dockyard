-- Bootstraps the PostgREST-owned schema containing:
-- - a table to store the active JWT secret and a function to rotate it.
-- - a pre_config function to load config values including the JWT secret into PostgREST's session.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA IF NOT EXISTS postgrest;
CREATE EXTENSION IF NOT EXISTS plpython3u;
-- Python provides some facilities that would be more complex in pure SQL, like generating a secure random JWT secret.
GRANT USAGE ON SCHEMA postgrest TO authenticator;
-- We'll store the current (Singleton) JWT secret in the DB so it can be rotated without config file changes or restarts.
CREATE TABLE IF NOT EXISTS postgrest.jwt_secret (
    secret text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS jwt_secret_singleton_idx ON postgrest.jwt_secret ((TRUE));
-- Python function to generate a new random secret and upsert it into the singleton jwt_secret table.
-- Not exposed to public and only callable by superusers to prevent accidental
-- or malicious rotations that would invalidate all existing tokens.
CREATE OR REPLACE FUNCTION postgrest.rotate_jwt_secret ()
    RETURNS void
    AS $$
  import secrets

  secret = secrets.token_hex(256)
  plan = plpy.prepare("""
    INSERT INTO postgrest.jwt_secret (secret, updated_at)
    VALUES ($1, now())
    ON CONFLICT ((true)) DO UPDATE
    SET secret = EXCLUDED.secret,
        updated_at = now()
  """, ["text"])

  plpy.execute(plan, [secret])
$$
LANGUAGE plpython3u;
REVOKE ALL ON FUNCTION postgrest.rotate_jwt_secret () FROM PUBLIC;
-- Initialize once on first boot; function remains available for future rotations.
SELECT
    postgrest.rotate_jwt_secret ();
-- Called by PostgREST on config reload/startup to pull the active secret.
CREATE OR REPLACE FUNCTION postgrest.pre_config ()
    RETURNS void
    AS $$
    SELECT
        set_config('pgrst.jwt_secret', secret, TRUE)
    FROM
        postgrest.jwt_secret
    LIMIT 1;
$$
LANGUAGE sql;
COMMIT;

