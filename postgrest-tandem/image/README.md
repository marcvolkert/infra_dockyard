# PostgREST-Ready PostgreSQL Image

PostgreSQL image for PostgREST-backed workloads.

Key features: database-managed JWT secret, built-in auth/login RPC bootstrap, password hashing with pgcrypto, and plpython-based JWT signing without pgjwt.

For more information, see the official PostgREST docs: https://postgrest.org/en/stable/

Note: commands below use `podman`; using `docker` should work by replacing the binary name.

## Files

- `Containerfile`: Postgres base image plus runtime dependency (`plpython3u`).
- `initdb/`: bootstrap scripts executed on first database initialization.

## Init order

Entrypoint runs scripts lexicographically:

1. `initdb/01-init.sh`
   - creates/updates `authenticator`
2. `initdb/02-postgrest.sql`
   - creates the `postgrest` schema objects
   - creates/rotates JWT secret in `postgrest.jwt_secret`
   - defines `postgrest.pre_config()` so PostgREST reads secret from DB
3. `initdb/03-auth.sql`
   - creates `auth` schema and `auth.users`
   - hashes passwords and validates role names
   - defines JWT signer and `auth.login`
4. `initdb/04-anon.sql`
   - creates `anon` role and `api` schema
   - exposes `api.login` and grants execute to `anon`

## Build

```bash
cd postgrest-tandem/image
VERSION=1.2.3

# optional metadata from git
GIT_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"

# build one image with multiple tags
podman build -f Containerfile . \
   --build-arg IMAGE_VERSION="$VERSION" \
   --build-arg VCS_REF="$GIT_SHA" \
   --build-arg POSTGRES_BASE_TAG=16 \
   -t localhost/postgrest-db:"$VERSION" \
   -t localhost/postgrest-db:"${VERSION%.*}" \
   -t localhost/postgrest-db:latest
```

Tag strategy in the example above:

- `1.2.3` -> immutable release tag
- `1.2` -> moving minor line
- `latest` -> moving default tag

If you publish to a registry, replace `localhost/postgrest-db` with your image path (for example `ghcr.io/<owner>/postgrest-db`).

## Run

For additional supported environment variables, see the official Postgres image docs: https://hub.docker.com/_/postgres

```bash
cd postgrest-tandem/image
export POSTGRES_PASSWORD='postgres'
export AUTHENTICATOR_PASSWORD='authenticator'
podman run --rm --name postgrest-db -p 5432:5432 \
   -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
   -e AUTHENTICATOR_PASSWORD="$AUTHENTICATOR_PASSWORD" \
   localhost/postgrest-db:1.2.3
```

Optional:

```bash
# detached + persistent data volume
podman run -d --name postgrest-db -p 5433:5432 \
   -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
   -e AUTHENTICATOR_PASSWORD="$AUTHENTICATOR_PASSWORD" \
   -v postgrest-pgdata:/var/lib/postgresql/data \
   localhost/postgrest-db:1.2.3
```

## Smoke test

1. Verify the database is up:

```bash
psql "postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" -c 'select current_user, current_database();'
```

2. Create a test user:

```bash
psql "postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/postgres" <<'SQL'
INSERT INTO auth.users (username, password, role)
VALUES ('alice', 'hunter2hunter2', 'anon')
ON CONFLICT (username) DO UPDATE
   SET password = EXCLUDED.password,
         role     = EXCLUDED.role;
SQL
```

3. If you have a PostgREST instance pointed at this database, request a token:

```bash
curl -fsS -X POST http://localhost:3000/rpc/login \
   -H 'Content-Type: application/json' \
   -H 'Accept: application/json' \
   --data '{"username":"alice","password":"hunter2hunter2"}'
```

4. Extract the bearer token only:

```bash
TOKEN="$(curl -fsS -X POST http://localhost:3000/rpc/login \
   -H 'Content-Type: application/json' \
   --data '{"username":"alice","password":"hunter2hunter2"}' \
   | jq -r '.token')"

echo "$TOKEN"
```

The token is suitable for `Authorization: Bearer <token>`.

## Local integration tests (BATS)

The integration suite under `postgrest-tandem/tests/` validates bootstrap scripts, auth/JWT behavior, and privilege boundaries directly via `psql`.

### Prerequisites

- Docker (or Podman with equivalent commands)
- `bats`, `jq`, and `psql` available on your machine

### Run locally

From the repository root:

```bash
# Build the image used by the test harness.
docker build -f postgrest-tandem/image/Containerfile postgrest-tandem/image \
  -t local/postgrest-db:ci

# Execute all integration tests.
TEST_IMAGE=local/postgrest-db:ci bats postgrest-tandem/tests/

# Or run with podman.
podman build -f postgrest-tandem/image/Containerfile postgrest-tandem/image \
  -t local/postgrest-db:ci
CONTAINER_RUNTIME=podman TEST_IMAGE=local/postgrest-db:ci bats postgrest-tandem/tests/
```

Notes:

- The test harness uses a fixed dummy credential (`AUTHENTICATOR_PASSWORD=testpw-ci-only`) for CI/local testing only.
- Tests start and remove their own temporary database container.

## Notes

- JWTs are signed (tamper-proof), not encrypted (readable by holder).
- Keep `postgrest.jwt_secret` private and rotate periodically.
- Existing tokens become invalid immediately after secret rotation.

## Upstream Attribution

This image is based on the official PostgreSQL container image (`postgres`) and includes PostgreSQL software distributed under the PostgreSQL License.

- Official PostgreSQL license: https://www.postgresql.org/about/licence/
- Official Postgres container image: https://hub.docker.com/_/postgres
