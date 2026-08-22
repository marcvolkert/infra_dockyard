"""Permission-boundary and security-definer integration tests."""

import pytest

pytestmark = pytest.mark.usefixtures("alice_user")


def test_sign_jwt_denied_for_public_and_anon(postgrest_db):
    """Non-privileged roles cannot call the low-level JWT signer."""
    result = postgrest_db.psql_authenticator('SELECT auth.sign_jwt(\'{"role":"anon"}\'::jsonb);')
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator(
        'SET ROLE anon; SELECT auth.sign_jwt(\'{"role":"anon"}\'::jsonb);'
    )
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_rotate_secret_denied_for_public_and_anon(postgrest_db):
    """Non-privileged roles cannot rotate JWT secrets."""
    result = postgrest_db.psql_authenticator("SELECT postgrest.rotate_jwt_secret();")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT postgrest.rotate_jwt_secret();")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_auth_login_denied_for_anon(postgrest_db):
    """The anon role cannot execute auth.login directly."""
    result = postgrest_db.psql_authenticator(
        "SET ROLE anon; SELECT auth.login('alice', 'correct-password');"
    )
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_api_login_execute_privileges(postgrest_db):
    """EXECUTE on api.login is granted to anon and denied to others."""
    result = postgrest_db.psql_super(
        "SELECT has_function_privilege('anon', 'api.login(text,text)', 'EXECUTE') || '|' || "
        "has_function_privilege('authenticator', 'api.login(text,text)', 'EXECUTE') || '|' || "
        "has_function_privilege('public', 'api.login(text,text)', 'EXECUTE');"
    )
    assert result.returncode == 0, result.output
    assert result.stdout == "true|false|false"


def test_api_login_requires_anon_role(postgrest_db):
    """Authenticator must SET ROLE anon before calling api.login."""
    result = postgrest_db.psql_authenticator("SELECT api.login('alice', 'correct-password');")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator(
        "SET ROLE anon; SELECT (api.login('alice', 'correct-password')).token;"
    )
    assert result.returncode == 0, result.output
    token = result.stdout.splitlines()[-1]
    assert token
    assert len(token.split(".")) == 3


def test_api_login_wrong_password_sqlstate(postgrest_db):
    """api.login preserves invalid_password SQLSTATE 28P01 semantics."""
    sql = """
    SET ROLE anon;
    DO $$ BEGIN
      PERFORM api.login('alice', 'wrong-password');
      RAISE EXCEPTION 'expected invalid password';
    EXCEPTION WHEN invalid_password THEN
      RAISE NOTICE 'caught:%', SQLSTATE;
    END $$;
    """
    result = postgrest_db.psql_authenticator(sql)
    assert result.returncode == 0, result.output
    assert "caught:28P01" in result.output


def test_anon_cannot_read_secret_or_users(postgrest_db):
    """anon cannot read JWT secret material or auth.users rows."""
    result = postgrest_db.psql_authenticator(
        "SET ROLE anon; SELECT secret FROM postgrest.jwt_secret LIMIT 1;"
    )
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator(
        "SET ROLE anon; SELECT username FROM auth.users LIMIT 1;"
    )
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_authenticator_cannot_read_users(postgrest_db):
    """authenticator role cannot directly read auth.users."""
    result = postgrest_db.psql_authenticator("SELECT username FROM auth.users LIMIT 1;")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_login_functions_security_definer_owner(postgrest_db):
    """login functions are SECURITY DEFINER and owned by postgres."""
    result = postgrest_db.psql_super(
        "SELECT n.nspname || '.' || p.proname || '|' || p.prosecdef || '|' || pg_get_userbyid(p.proowner) "
        "FROM pg_proc p "
        "JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE (n.nspname, p.proname) IN (('api', 'login'), ('auth', 'login')) "
        "ORDER BY n.nspname;"
    )
    assert result.returncode == 0, result.output
    assert result.stdout == "api.login|true|postgres\nauth.login|true|postgres"
