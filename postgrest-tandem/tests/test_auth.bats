#!/usr/bin/env bats

load ./test_helper.bash

setup_file() {
  start_postgrest_db
  ensure_alice_user
}

teardown_file() {
  stop_postgrest_db
}

@test "storing a user hashes password with bcrypt" {
  run psql_super "SELECT password FROM auth.users WHERE username = 'alice';"
  [ "$status" -eq 0 ]
  [[ "$output" == \$2a\$* || "$output" == \$2b\$* ]]
}

@test "auth.login returns a JWT with role and ~15 minute expiry" {
  run psql_super "SELECT (auth.login('alice', 'correct-password')).token;"
  [ "$status" -eq 0 ]
  token="$output"
  [ -n "$token" ]

  part_count="$(printf '%s' "$token" | awk -F'.' '{print NF}')"
  [ "$part_count" -eq 3 ]

  payload_json="$(decode_jwt_payload "$token")"
  role="$(printf '%s' "$payload_json" | jq -r '.role')"
  exp="$(printf '%s' "$payload_json" | jq -r '.exp')"
  now_epoch="$(date +%s)"

  [ "$role" = "anon" ]
  [ "$exp" -ge $((now_epoch + 14 * 60)) ]
  [ "$exp" -le $((now_epoch + 16 * 60)) ]
}

@test "auth.login wrong password raises invalid_password SQLSTATE 28P01" {
  run psql_super "DO \
  \\$\\$ BEGIN \
    PERFORM auth.login('alice', 'wrong-password'); \
    RAISE EXCEPTION 'expected invalid password'; \
  EXCEPTION WHEN invalid_password THEN \
    RAISE NOTICE 'caught:%', SQLSTATE; \
  END \\$\\$;"
  [ "$status" -eq 0 ]
  [[ "$output" == *"caught:28P01"* ]]
}

@test "inserting user with unknown role is rejected" {
  run psql_super_raw "INSERT INTO auth.users (username, password, role) VALUES ('missing-role', 'correct-password', 'does_not_exist');"
  [ "$status" -ne 0 ]
  [[ "$output" == *"role \"does_not_exist\" does not exist"* ]]
}

@test "inserting user with short password is rejected" {
  run psql_super_raw "INSERT INTO auth.users (username, password, role) VALUES ('short-pass', 'short', 'anon');"
  [ "$status" -ne 0 ]
  [[ "$output" == *"violates check constraint"* ]]
}

@test "updating password re-hashes to a different bcrypt hash" {
  run psql_super "SELECT password FROM auth.users WHERE username = 'alice';"
  [ "$status" -eq 0 ]
  before_hash="$output"

  run psql_super "UPDATE auth.users SET password = 'new-correct-password' WHERE username = 'alice';"
  [ "$status" -eq 0 ]

  run psql_super "SELECT password FROM auth.users WHERE username = 'alice';"
  [ "$status" -eq 0 ]
  after_hash="$output"

  [[ "$after_hash" == \$2a\$* || "$after_hash" == \$2b\$* ]]
  [ "$before_hash" != "$after_hash" ]
}
