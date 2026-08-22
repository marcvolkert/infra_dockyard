"""Authentication behavior integration tests."""

import time

import pytest

pytestmark = pytest.mark.usefixtures("alice_user")


def test_user_password_is_bcrypt(postgrest_db):
    """Persisted user passwords are stored as bcrypt hashes."""
    result = postgrest_db.psql_super("SELECT password FROM auth.users WHERE username = 'alice';")
    assert result.returncode == 0, result.output
    assert result.stdout.startswith(("$2a$", "$2b$"))


def test_auth_login_returns_jwt(postgrest_db):
    """Successful login returns a JWT with anon role and ~15 minute expiry."""
    result = postgrest_db.psql_super("SELECT (auth.login('alice', 'correct-password')).token;")
    assert result.returncode == 0, result.output
    token = result.stdout
    assert token
    assert len(token.split(".")) == 3

    payload = postgrest_db.decode_jwt_payload(token)
    now_epoch = int(time.time())

    assert payload["role"] == "anon"
    assert now_epoch + 14 * 60 <= int(payload["exp"]) <= now_epoch + 16 * 60


def test_auth_login_wrong_password_sqlstate(postgrest_db):
    """Wrong password preserves PostgreSQL invalid_password SQLSTATE 28P01."""
    sql = """
    DO $$ BEGIN
      PERFORM auth.login('alice', 'wrong-password');
      RAISE EXCEPTION 'expected invalid password';
    EXCEPTION WHEN invalid_password THEN
      RAISE NOTICE 'caught:%', SQLSTATE;
    END $$;
    """
    result = postgrest_db.psql_super(sql)
    assert result.returncode == 0, result.output
    assert "caught:28P01" in result.output


def test_insert_user_unknown_role(postgrest_db):
    """Inserts fail when referencing a role that does not exist."""
    result = postgrest_db.psql_super_raw(
        "INSERT INTO auth.users (username, password, role) "
        "VALUES ('missing-role', 'correct-password', 'does_not_exist');"
    )
    assert result.returncode != 0
    assert 'role "does_not_exist" does not exist' in result.output


def test_insert_user_short_password(postgrest_db):
    """Inserts fail for passwords shorter than policy minimum."""
    result = postgrest_db.psql_super_raw(
        "INSERT INTO auth.users (username, password, role) VALUES ('short-pass', 'short', 'anon');"
    )
    assert result.returncode != 0
    assert "password must be between 8 and 512 characters" in result.output


def test_update_password_rehashes(postgrest_db):
    """Password updates rehash and change the stored bcrypt value."""
    result = postgrest_db.psql_super("SELECT password FROM auth.users WHERE username = 'alice';")
    assert result.returncode == 0, result.output
    before_hash = result.stdout

    result = postgrest_db.psql_super(
        "UPDATE auth.users SET password = 'new-correct-password' WHERE username = 'alice';"
    )
    assert result.returncode == 0, result.output

    result = postgrest_db.psql_super("SELECT password FROM auth.users WHERE username = 'alice';")
    assert result.returncode == 0, result.output
    after_hash = result.stdout

    assert after_hash.startswith(("$2a$", "$2b$"))
    assert after_hash != before_hash
