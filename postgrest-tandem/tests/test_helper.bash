#!/usr/bin/env bash

POSTGREST_DB_CONTAINER="postgrest-db-bats"
POSTGREST_DB_PORT="55432"
POSTGRES_PASSWORD="postgres-ci-only"
AUTHENTICATOR_PASSWORD="testpw-ci-only"
TEST_IMAGE="${TEST_IMAGE:-local/postgrest-db:ci}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"

ctr() {
  command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 || {
    echo "container runtime not found: $CONTAINER_RUNTIME" >&2
    return 1
  }
  "$CONTAINER_RUNTIME" "$@"
}

psql_super() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U postgres -d postgres -c "$1"
}

psql_super_raw() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U postgres -d postgres -c "$1"
}

psql_authenticator() {
  PGPASSWORD="$AUTHENTICATOR_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U authenticator -d postgres -c "$1"
}

wait_for_postgres() {
  local attempts=60
  while (( attempts > 0 )); do
    if psql_super 'SELECT 1;' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts - 1))
  done
  return 1
}

start_postgrest_db() {
  ctr rm -f "$POSTGREST_DB_CONTAINER" >/dev/null 2>&1 || true
  ctr run -d --name "$POSTGREST_DB_CONTAINER" \
    -p "$POSTGREST_DB_PORT:5432" \
    -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    -e AUTHENTICATOR_PASSWORD="$AUTHENTICATOR_PASSWORD" \
    "$TEST_IMAGE" >/dev/null

  if ! wait_for_postgres; then
    ctr logs "$POSTGREST_DB_CONTAINER" >&2 || true
    return 1
  fi
}

stop_postgrest_db() {
  ctr rm -f "$POSTGREST_DB_CONTAINER" >/dev/null 2>&1 || true
}

ensure_alice_user() {
  psql_super "
    INSERT INTO auth.users (username, password, role)
    VALUES ('alice', 'correct-password', 'anon')
    ON CONFLICT (username) DO UPDATE
      SET password = EXCLUDED.password,
          role = EXCLUDED.role;
  "
}

decode_jwt_payload() {
  local token="$1"
  local payload
  local rem

  payload="$(printf '%s' "$token" | cut -d'.' -f2 | tr '_-' '/+')"
  rem=$(( ${#payload} % 4 ))
  if [ "$rem" -eq 2 ]; then
    payload+="=="
  elif [ "$rem" -eq 3 ]; then
    payload+="="
  elif [ "$rem" -eq 1 ]; then
    return 1
  fi

  printf '%s' "$payload" | base64 --decode
}
