import pytest


pytestmark = pytest.mark.usefixtures("alice_user")


def test_public_and_anon_cannot_call_auth_sign_jwt(postgrest_db):
    result = postgrest_db.psql_authenticator("SELECT auth.sign_jwt('{\"role\":\"anon\"}'::jsonb);")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator(
        "SET ROLE anon; SELECT auth.sign_jwt('{\"role\":\"anon\"}'::jsonb);"
    )
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_public_and_anon_cannot_rotate_jwt_secret(postgrest_db):
    result = postgrest_db.psql_authenticator("SELECT postgrest.rotate_jwt_secret();")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT postgrest.rotate_jwt_secret();")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_anon_cannot_call_auth_login_directly(postgrest_db):
    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT auth.login('alice', 'correct-password');")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_api_login_execute_privilege_is_restricted_to_anon(postgrest_db):
    result = postgrest_db.psql_super(
        "SELECT has_function_privilege('anon', 'api.login(text,text)', 'EXECUTE') || '|' || "
        "has_function_privilege('authenticator', 'api.login(text,text)', 'EXECUTE') || '|' || "
        "has_function_privilege('public', 'api.login(text,text)', 'EXECUTE');"
    )
    assert result.returncode == 0, result.output
    assert result.stdout == "true|false|false"


def test_api_login_requires_role_switch_to_anon_for_authenticator_session(postgrest_db):
    result = postgrest_db.psql_authenticator("SELECT api.login('alice', 'correct-password');")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT (api.login('alice', 'correct-password')).token;")
    assert result.returncode == 0, result.output
    token = result.stdout.splitlines()[-1]
    assert token
    assert len(token.split(".")) == 3


def test_api_login_called_as_anon_preserves_invalid_password_sqlstate_28p01(postgrest_db):
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


def test_anon_cannot_select_postgrest_jwt_secret_or_auth_users(postgrest_db):
    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT secret FROM postgrest.jwt_secret LIMIT 1;")
    assert result.returncode != 0
    assert "permission denied" in result.output

    result = postgrest_db.psql_authenticator("SET ROLE anon; SELECT username FROM auth.users LIMIT 1;")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_authenticator_cannot_select_auth_users_directly(postgrest_db):
    result = postgrest_db.psql_authenticator("SELECT username FROM auth.users LIMIT 1;")
    assert result.returncode != 0
    assert "permission denied" in result.output


def test_api_login_and_auth_login_are_security_definer_owned_by_postgres(postgrest_db):
    result = postgrest_db.psql_super(
        "SELECT n.nspname || '.' || p.proname || '|' || p.prosecdef || '|' || pg_get_userbyid(p.proowner) "
        "FROM pg_proc p "
        "JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE (n.nspname, p.proname) IN (('api', 'login'), ('auth', 'login')) "
        "ORDER BY n.nspname;"
    )
    assert result.returncode == 0, result.output
    assert result.stdout == "api.login|true|postgres\nauth.login|true|postgres"
