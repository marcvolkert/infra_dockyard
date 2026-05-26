#!/usr/bin/env bats

load ./test_helper.bash

setup_file() {
  start_postgrest_db
  ensure_alice_user
}

teardown_file() {
  stop_postgrest_db
}

@test "api.login called as anon returns valid JWT" {
  run psql_authenticator "SET ROLE anon; SELECT (api.login('alice', 'correct-password')).token;"
  [ "$status" -eq 0 ]
  token="$(printf '%s\n' "$output" | tail -n1)"
  [ -n "$token" ]

  part_count="$(printf '%s' "$token" | awk -F'.' '{print NF}')"
  [ "$part_count" -eq 3 ]
}

@test "api.login called as anon with wrong password raises invalid_password" {
  run psql_authenticator "SET ROLE anon; DO \
  \\$\\$ BEGIN \
    PERFORM api.login('alice', 'wrong-password'); \
    RAISE EXCEPTION 'expected invalid password'; \
  EXCEPTION WHEN invalid_password THEN \
    RAISE NOTICE 'caught:%', SQLSTATE; \
  END \\$\\$;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"caught:28P01"* ]]
}
