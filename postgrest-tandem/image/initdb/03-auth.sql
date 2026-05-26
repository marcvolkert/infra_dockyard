-- Bootstraps the auth schema containing:
-- - users table with bcrypt-hashed passwords and a role column for JWT claims.
-- - sign_jwt function to generate JWTs with the active secret from postgrest.jwt_secret.
-- - login RPC to verify credentials and return a JWT.
\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA auth;
-- User data with hashed passwords and a role for JWT claims.
-- Two triggers are needed:
-- 1) hash_password: on write, hash the plaintext password using bcrypt.
-- 2) check_role: ensure the role exists to prevent PostgREST from issuing
--    tokens with un-switchable roles.
CREATE TABLE IF NOT EXISTS auth.users (
    id serial PRIMARY KEY,
    username text UNIQUE NOT NULL,
    password TEXT NOT NULL CHECK (password ~ '^\$2[abxy]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'), -- Enforce bcrypt hash format
    role TEXT NOT NULL CHECK (length(ROLE) < 512) DEFAULT 'anon'
);
CREATE OR REPLACE FUNCTION auth.hash_password ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF NEW.password IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.password <> OLD.password) THEN
        IF length(NEW.password) < 8 OR length(NEW.password) > 512 THEN
            RAISE EXCEPTION 'password must be between 8 and 512 characters'
                USING ERRCODE = '22023';
        END IF;
        NEW.password := auth.crypt(NEW.password, auth.gen_salt('bf'));
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;
CREATE TRIGGER hash_password_trigger
    BEFORE INSERT OR UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION auth.hash_password ();
CREATE OR REPLACE FUNCTION auth.check_role ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF NOT EXISTS (
        SELECT
        FROM
            pg_roles
        WHERE
            rolname = NEW.role) THEN
    RAISE EXCEPTION 'role "%" does not exist', NEW.role;
END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;
CREATE CONSTRAINT TRIGGER check_role_trigger
    AFTER INSERT OR UPDATE ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION auth.check_role ();
-- Now that the user table is set up, we provide facilities to generate JWTs for authenticated users.
-- The login RPC is defined in 03-anon.sql, but the underlying signer function is here since it needs access to the JWT secret and we want to keep that out of reach from the anon role.
DO $$
BEGIN
    CREATE TYPE auth.jwt_token AS (
        token text
);
EXCEPTION
    WHEN duplicate_object THEN
        NULL;
END
$$;
CREATE OR REPLACE FUNCTION auth.sign_jwt (payload jsonb)
    RETURNS auth.jwt_token
    AS $$
  import hmac, hashlib, base64, json

  claims = json.loads(payload)

  rv = plpy.execute(
    "SELECT secret FROM postgrest.jwt_secret LIMIT 1", 1
  )
  if not rv:
    plpy.error("postgrest.jwt_secret is not initialised")
  key = rv[0]["secret"]

  def b64url(data: bytes) -> str:
    """ Encode bytes to base64url string without padding, as per JWT spec."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

  header_b64  = b64url(json.dumps({"alg": "HS256", "typ": "JWT"},
                                  separators=(",", ":")).encode())
  payload_b64 = b64url(json.dumps(claims, separators=(",", ":")).encode())
  signing_in  = f"{header_b64}.{payload_b64}".encode("ascii")
  sig_b64     = b64url(hmac.new(key.encode(), signing_in, hashlib.sha256).digest())

  return (f"{header_b64}.{payload_b64}.{sig_b64}",)
$$
LANGUAGE plpython3u;
REVOKE ALL ON FUNCTION auth.sign_jwt (jsonb) FROM PUBLIC;
-- With the user table and JWT signer in place, we can implement the login RPC that PostgREST will expose to anonymous callers.
-- It verifies credentials and returns a signed JWT with the user's role and a short expiry.
CREATE OR REPLACE FUNCTION auth.login (username text, PASSWORD TEXT)
    RETURNS auth.jwt_token
    AS $$
DECLARE
    user_record auth.users%ROWTYPE;
BEGIN
    SELECT
        *
    INTO
        user_record
    FROM
        auth.users
    WHERE
        auth.users.username = login.username;
    IF user_record IS NULL OR auth.crypt(login.password, user_record.password) <> user_record.password THEN
        RAISE invalid_password
        USING MESSAGE = 'invalid username or password';
    END IF;
        RETURN auth.sign_jwt (jsonb_build_object('role', user_record.role, 'exp', extract(epoch FROM now() + interval '15 minutes')::int));
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;
REVOKE ALL ON FUNCTION auth.login (text, text) FROM PUBLIC;
COMMIT;

