#!/usr/bin/env bash

POSTGREST_DB_CONTAINER="postgrest-db-bats"
POSTGREST_DB_PORT="55432"
POSTGRES_PASSWORD="postgres-ci-only"
AUTHENTICATOR_PASSWORD="testpw-ci-only"
TEST_IMAGE="${TEST_IMAGE:-local/postgrest-db:ci}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"

# Wrapper around the configured container runtime (podman/docker).
ctr() {
  command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1 || {
    echo "container runtime not found: $CONTAINER_RUNTIME" >&2
    return 1
  }
  "$CONTAINER_RUNTIME" "$@"
}

# Runs a SQL command as the postgres superuser. Aborts on error (-v ON_ERROR_STOP=1).
psql_super() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U postgres -d postgres -c "$1"
}

# Like psql_super but without ON_ERROR_STOP, so callers can inspect failures.
psql_super_raw() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql -X -qAt \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U postgres -d postgres -c "$1"
}

# Runs a SQL command as the PostgREST authenticator role.
psql_authenticator() {
  PGPASSWORD="$AUTHENTICATOR_PASSWORD" psql -X -qAt -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -p "$POSTGREST_DB_PORT" -U authenticator -d postgres -c "$1"
}

# Polls Postgres until it accepts connections, retrying once per second for up
# to 60 seconds. Returns 1 if the database never becomes reachable.
wait_for_postgres() {
  local attempts=60
  while ((attempts > 0)); do
    if psql_super 'SELECT 1;' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts - 1))
  done
  return 1
}

# Removes any existing test container, starts a fresh one, and waits for
# Postgres to be ready. Dumps container logs and returns 1 on timeout.
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

# Force-removes the test database container, ignoring errors if it doesn't exist.
stop_postgrest_db() {
  ctr rm -f "$POSTGREST_DB_CONTAINER" >/dev/null 2>&1 || true
}

# Upserts the 'alice' test user in auth.users, ensuring a known password and
# role are present regardless of prior test state.
ensure_alice_user() {
  psql_super "
    INSERT INTO auth.users (username, password, role)
    VALUES ('alice', 'correct-password', 'anon')
    ON CONFLICT (username) DO UPDATE
      SET password = EXCLUDED.password,
          role = EXCLUDED.role;
  "
}

# Decodes and prints the JSON payload of a JWT (the middle dot-separated part).
# Handles URL-safe base64 by swapping _ and - back to / and +, and pads the
# string to a valid base64 length before decoding. Returns 1 for malformed tokens.
decode_jwt_payload() {
  local token="$1"
  local payload
  local rem

  payload="$(printf '%s' "$token" | cut -d'.' -f2 | tr '_-' '/+')"
  rem=$((${#payload} % 4))
  if [ "$rem" -eq 2 ]; then
    payload+="=="
  elif [ "$rem" -eq 3 ]; then
    payload+="="
  elif [ "$rem" -eq 1 ]; then
    return 1
  fi

  printf '%s' "$payload" | base64 --decode
}
