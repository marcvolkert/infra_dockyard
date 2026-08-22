"""JWT secret bootstrap and rotation integration tests."""


def test_jwt_secret_singleton(postgrest_db):
    """JWT secret table stores exactly one sufficiently long secret."""
    result = postgrest_db.psql_super("SELECT count(*) FROM postgrest.jwt_secret;")
    assert result.returncode == 0, result.output
    assert result.stdout == "1"

    result = postgrest_db.psql_super("SELECT length(secret) FROM postgrest.jwt_secret LIMIT 1;")
    assert result.returncode == 0, result.output
    assert int(result.stdout) >= 64


def test_pre_config_sets_jwt_secret(postgrest_db):
    """pre_config publishes the same secret through pgrst.jwt_secret."""
    result = postgrest_db.psql_super(
        "WITH cfg AS (SELECT postgrest.pre_config()) "
        "SELECT current_setting('pgrst.jwt_secret', true) FROM cfg;"
    )
    assert result.returncode == 0, result.output
    config_secret = result.stdout

    result = postgrest_db.psql_super("SELECT secret FROM postgrest.jwt_secret LIMIT 1;")
    assert result.returncode == 0, result.output
    assert result.stdout == config_secret


def test_rotate_jwt_secret(postgrest_db):
    """Secret rotation changes secret material and bumps updated_at."""
    result = postgrest_db.psql_super(
        "SELECT secret || '|' || updated_at::text FROM postgrest.jwt_secret LIMIT 1;"
    )
    assert result.returncode == 0, result.output
    before_secret, before_updated_at = postgrest_db.parse_secret_row(result.stdout)

    result = postgrest_db.psql_super("SELECT pg_sleep(1); SELECT postgrest.rotate_jwt_secret();")
    assert result.returncode == 0, result.output

    result = postgrest_db.psql_super(
        "SELECT secret || '|' || updated_at::text FROM postgrest.jwt_secret LIMIT 1;"
    )
    assert result.returncode == 0, result.output
    after_secret, after_updated_at = postgrest_db.parse_secret_row(result.stdout)

    assert after_secret != before_secret
    assert after_updated_at > before_updated_at
