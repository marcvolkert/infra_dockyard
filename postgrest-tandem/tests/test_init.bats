#!/usr/bin/env bats

load ./test_helper.bash

setup_file() {
  start_postgrest_db
}

teardown_file() {
  stop_postgrest_db
}

@test "authenticator and anon roles are bootstrapped correctly" {
  run psql_super "SELECT rolname || '|' || rolcanlogin || '|' || rolinherit FROM pg_roles WHERE rolname = 'authenticator';"
  [ "$status" -eq 0 ]
  [ "$output" = "authenticator|t|f" ]

  run psql_super "SELECT rolname || '|' || rolcanlogin FROM pg_roles WHERE rolname = 'anon';"
  [ "$status" -eq 0 ]
  [ "$output" = "anon|f" ]

  run psql_super "SELECT pg_has_role('authenticator', 'anon', 'member');"
  [ "$status" -eq 0 ]
  [ "$output" = "t" ]
}

@test "required schemas exist" {
  run psql_super "SELECT string_agg(nspname, ',') FROM (SELECT nspname FROM pg_namespace WHERE nspname IN ('postgrest','auth','api') ORDER BY nspname) s;"
  [ "$status" -eq 0 ]
  [ "$output" = "api,auth,postgrest" ]
}

@test "required extensions are installed" {
  run psql_super "SELECT string_agg(extname, ',') FROM (SELECT extname FROM pg_extension WHERE extname IN ('plpython3u','pgcrypto') ORDER BY extname) e;"
  [ "$status" -eq 0 ]
  [ "$output" = "pgcrypto,plpython3u" ]
}
