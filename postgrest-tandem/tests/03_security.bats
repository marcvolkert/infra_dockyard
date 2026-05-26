#!/usr/bin/env bats

load ./test_helper.bash

setup_file() {
  start_postgrest_db
  ensure_alice_user
}

teardown_file() {
  stop_postgrest_db
}

@test "public/anon cannot call auth.sign_jwt" {
  run psql_authenticator "SELECT auth.sign_jwt('{\"role\":\"anon\"}'::jsonb);"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]

  run psql_authenticator "SET ROLE anon; SELECT auth.sign_jwt('{\"role\":\"anon\"}'::jsonb);"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
}

@test "public/anon cannot rotate JWT secret" {
  run psql_authenticator "SELECT postgrest.rotate_jwt_secret();"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]

  run psql_authenticator "SET ROLE anon; SELECT postgrest.rotate_jwt_secret();"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
}

@test "anon cannot call auth.login directly" {
  run psql_authenticator "SET ROLE anon; SELECT auth.login('alice', 'correct-password');"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
}

@test "api.login execute privilege is restricted to anon" {
  run psql_super "SELECT has_function_privilege('anon', 'api.login(text,text)', 'EXECUTE') || '|' || has_function_privilege('authenticator', 'api.login(text,text)', 'EXECUTE') || '|' || has_function_privilege('public', 'api.login(text,text)', 'EXECUTE');"
  [ "$status" -eq 0 ]
  [ "$output" = "true|false|false" ]
}

@test "api.login requires role switch to anon for authenticator session" {
  run psql_authenticator "SELECT api.login('alice', 'correct-password');"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]

  run psql_authenticator "SET ROLE anon; SELECT (api.login('alice', 'correct-password')).token;"
  [ "$status" -eq 0 ]
  token="$(printf '%s\n' "$output" | tail -n1)"
  [ -n "$token" ]

  part_count="$(printf '%s' "$token" | awk -F'.' '{print NF}')"
  [ "$part_count" -eq 3 ]
}

@test "api.login called as anon preserves invalid_password SQLSTATE 28P01" {
  read -r -d '' sql <<'SQL' || true
SET ROLE anon;
DO $$ BEGIN
  PERFORM api.login('alice', 'wrong-password');
  RAISE EXCEPTION 'expected invalid password';
EXCEPTION WHEN invalid_password THEN
  RAISE NOTICE 'caught:%', SQLSTATE;
END $$;
SQL

  run psql_authenticator "$sql"
  [ "$status" -eq 0 ]
  [[ "$output" == *"caught:28P01"* ]]
}

@test "anon cannot select postgrest.jwt_secret or auth.users" {
  run psql_authenticator "SET ROLE anon; SELECT secret FROM postgrest.jwt_secret LIMIT 1;"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]

  run psql_authenticator "SET ROLE anon; SELECT username FROM auth.users LIMIT 1;"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
}

@test "authenticator cannot select auth.users directly" {
  run psql_authenticator "SELECT username FROM auth.users LIMIT 1;"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
}

@test "api.login and auth.login are security definer owned by postgres" {
  run psql_super "SELECT n.nspname || '.' || p.proname || '|' || p.prosecdef || '|' || pg_get_userbyid(p.proowner) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE (n.nspname, p.proname) IN (('api', 'login'), ('auth', 'login')) ORDER BY n.nspname;"
  [ "$status" -eq 0 ]
  expected=$'api.login|true|postgres\nauth.login|true|postgres'
  [ "$output" = "$expected" ]
}
