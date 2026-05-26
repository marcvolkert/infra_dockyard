#!/usr/bin/env bats

load ./test_helper.bash

setup_file() {
  start_postgrest_db
}

teardown_file() {
  stop_postgrest_db
}

@test "jwt_secret singleton has exactly one non-empty long secret" {
  run psql_super "SELECT count(*) FROM postgrest.jwt_secret;"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]

  run psql_super "SELECT length(secret) FROM postgrest.jwt_secret LIMIT 1;"
  [ "$status" -eq 0 ]
  [ "$output" -ge 64 ]
}

@test "pre_config exposes the persisted secret via pgrst.jwt_secret" {
  run psql_super "WITH cfg AS (SELECT postgrest.pre_config()) SELECT current_setting('pgrst.jwt_secret', true) FROM cfg;"
  [ "$status" -eq 0 ]
  config_secret="$output"

  run psql_super "SELECT secret FROM postgrest.jwt_secret LIMIT 1;"
  [ "$status" -eq 0 ]
  [ "$output" = "$config_secret" ]
}

@test "rotate_jwt_secret changes secret and advances updated_at" {
  run psql_super "SELECT secret || '|' || extract(epoch FROM updated_at)::bigint FROM postgrest.jwt_secret LIMIT 1;"
  [ "$status" -eq 0 ]
  before="$output"

  run psql_super "SELECT pg_sleep(1); SELECT postgrest.rotate_jwt_secret();"
  [ "$status" -eq 0 ]

  run psql_super "SELECT secret || '|' || extract(epoch FROM updated_at)::bigint FROM postgrest.jwt_secret LIMIT 1;"
  [ "$status" -eq 0 ]
  after="$output"

  [ "$before" != "$after" ]

  before_secret="${before%%|*}"
  before_updated="${before##*|}"
  after_secret="${after%%|*}"
  after_updated="${after##*|}"

  [ "$before_secret" != "$after_secret" ]
  [ "$after_updated" -gt "$before_updated" ]
}
