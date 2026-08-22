import time

import pytest


pytestmark = pytest.mark.usefixtures("alice_user")


def test_storing_a_user_hashes_password_with_bcrypt(postgrest_db):
    result = postgrest_db.psql_super("SELECT password FROM auth.users WHERE username = 'alice';")
    assert result.returncode == 0, result.output
    assert result.stdout.startswith(("$2a$", "$2b$"))


def test_auth_login_returns_a_jwt_with_role_and_roughly_15_minute_expiry(postgrest_db):
    result = postgrest_db.psql_super("SELECT (auth.login('alice', 'correct-password')).token;")
    assert result.returncode == 0, result.output
    token = result.stdout
    assert token
    assert len(token.split(".")) == 3

    payload = postgrest_db.decode_jwt_payload(token)
    now_epoch = int(time.time())

    assert payload["role"] == "anon"
    assert now_epoch + 14 * 60 <= int(payload["exp"]) <= now_epoch + 16 * 60


def test_auth_login_wrong_password_raises_invalid_password_sqlstate_28p01(postgrest_db):
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


def test_inserting_user_with_unknown_role_is_rejected(postgrest_db):
    result = postgrest_db.psql_super_raw(
        "INSERT INTO auth.users (username, password, role) "
        "VALUES ('missing-role', 'correct-password', 'does_not_exist');"
    )
    assert result.returncode != 0
    assert 'role "does_not_exist" does not exist' in result.output


def test_inserting_user_with_short_password_is_rejected(postgrest_db):
    result = postgrest_db.psql_super_raw(
        "INSERT INTO auth.users (username, password, role) VALUES ('short-pass', 'short', 'anon');"
    )
    assert result.returncode != 0
    assert "password must be between 8 and 512 characters" in result.output


def test_updating_password_rehashes_to_a_different_bcrypt_hash(postgrest_db):
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
