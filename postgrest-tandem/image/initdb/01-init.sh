#!/bin/bash
# Creates the authenticator role needed by PostgREST to connect to Postgres.
set -euo pipefail
: "${AUTHENTICATOR_PASSWORD:?AUTHENTICATOR_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 --single-transaction \
  -v authpw="${AUTHENTICATOR_PASSWORD}" \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'EOSQL'
  -- Stage shell value in a session setting so dynamic SQL can read it
  -- safely without shell interpolation.
  SET LOCAL app.authpw = :'authpw';

  -- PostgREST connects as authenticator and switches into JWT roles.
  -- Keep it NOINHERIT so privileges only come from explicit SET ROLE.
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
      EXECUTE format('CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD %L',
                     current_setting('app.authpw'));
    ELSE
      EXECUTE format('ALTER ROLE authenticator WITH LOGIN PASSWORD %L',
                     current_setting('app.authpw'));
    END IF;
  END
  $$;
EOSQL
