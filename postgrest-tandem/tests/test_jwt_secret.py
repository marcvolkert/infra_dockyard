def test_jwt_secret_singleton_has_exactly_one_non_empty_long_secret(postgrest_db):
    result = postgrest_db.psql_super("SELECT count(*) FROM postgrest.jwt_secret;")
    assert result.returncode == 0, result.output
    assert result.stdout == "1"

    result = postgrest_db.psql_super("SELECT length(secret) FROM postgrest.jwt_secret LIMIT 1;")
    assert result.returncode == 0, result.output
    assert int(result.stdout) >= 64


def test_pre_config_exposes_the_persisted_secret_via_pgrst_jwt_secret(postgrest_db):
    result = postgrest_db.psql_super(
        "WITH cfg AS (SELECT postgrest.pre_config()) "
        "SELECT current_setting('pgrst.jwt_secret', true) FROM cfg;"
    )
    assert result.returncode == 0, result.output
    config_secret = result.stdout

    result = postgrest_db.psql_super("SELECT secret FROM postgrest.jwt_secret LIMIT 1;")
    assert result.returncode == 0, result.output
    assert result.stdout == config_secret


def test_rotate_jwt_secret_changes_secret_and_advances_updated_at(postgrest_db):
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
