# PostgREST-Ready PostgreSQL Image

PostgreSQL image for PostgREST-backed workloads.

## Table of Contents

- [Files](#files)
- [Init order](#init-order)
- [Build](#build)
- [Run](#run)
- [Smoke test](#smoke-test)
- [Local integration tests (pytest)](#local-integration-tests-pytest)
  - [Run locally](#run-locally)
- [CI/CD](#cicd)
  - [`test-postgrest-db` — integration tests on pull requests](#test-postgrest-db--integration-tests-on-pull-requests)
  - [`publish-postgrest-db` — image publish on release](#publish-postgrest-db--image-publish-on-release)
- [Notes](#notes)
- [Upstream Attribution](#upstream-attribution)

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

# build with a version tag and move the latest pointer
podman build -f Containerfile . \
   --build-arg IMAGE_VERSION="$VERSION" \
   --build-arg VCS_REF="$GIT_SHA" \
   --build-arg POSTGRES_BASE_TAG=16 \
   -t localhost/postgrest-db:"$VERSION" \
   -t localhost/postgrest-db:latest
```

Tag strategy in the example above:

- `1.2.3` -> immutable release tag
- `latest` -> moving default tag

If you publish to a registry, replace `localhost/postgrest-db` with your image path (for example `ghcr.io/<owner>/postgrest-db`).

## Run

For additional supported environment variables, see the official Postgres image docs: https://hub.docker.com/_/postgres

```bash
cd postgrest-tandem/image
VERSION=1.2.3
export POSTGRES_PASSWORD='postgres'
export AUTHENTICATOR_PASSWORD='authenticator'
podman run --rm --name postgrest-db -p 5432:5432 \
   -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
   -e AUTHENTICATOR_PASSWORD="$AUTHENTICATOR_PASSWORD" \
   localhost/postgrest-db:"$VERSION"
```

Optional:

```bash
# detached + persistent data volume
podman run -d --name postgrest-db -p 5433:5432 \
   -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
   -e AUTHENTICATOR_PASSWORD="$AUTHENTICATOR_PASSWORD" \
   -v postgrest-pgdata:/var/lib/postgresql/data \
   localhost/postgrest-db:"$VERSION"
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

## Local integration tests (pytest)

The integration suite under `postgrest-tandem/tests/` validates bootstrap scripts, auth/JWT behavior, and privilege boundaries directly via `psql`.

### Run locally

From the repository root:

Create a virtual environment, install the test dependency, then run pytest:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r postgrest-tandem/requirements-test.txt
pytest postgrest-tandem/tests/ -v
```

Notes:

- The test harness uses a fixed dummy credential (`AUTHENTICATOR_PASSWORD=testpw-ci-only`) for CI/local testing only.
- Tests require `psql` plus `podman` or `docker` on your PATH.
- Tests start and remove their own temporary database container.

## CI/CD

Two workflows ship with this repository, both located under `.github/workflows/`.

### `test-postgrest-db` — integration tests on pull requests

**Trigger:** any pull request that targets `dev` or `main` and touches a file inside `postgrest-tandem/**`.

**Jobs (sequential):**

1. **build** — builds the image with `docker/build-push-action` and exports it as a `.tar` artifact (`postgrest-db-image`).
2. **integration-test** — downloads the artifact, loads it with `docker load`, creates a temporary Python virtualenv, installs `pytest`, and runs `pytest postgrest-tandem/tests/ -v` with `TEST_IMAGE=local/postgrest-db:ci`.

The workflow uses the same image tag (`local/postgrest-db:ci`) and the same dummy credentials (`AUTHENTICATOR_PASSWORD=testpw-ci-only`) as the local test instructions above.

### `publish-postgrest-db` — image publish on release

**Trigger:** a GitHub release is published (i.e. the `published` release event). Works for both full releases and pre-releases.

**Steps:**

1. **Determine release channel** — strips the leading `v` from the tag name and sets `channel=release` (or `prerelease` for pre-releases).
2. **Log in to GHCR** — authenticates with `secrets.GITHUB_TOKEN` (no additional secrets needed).
3. **Extract Docker metadata** — builds the tag list:
   - `ghcr.io/<owner>/postgrest-db:<version>` — always applied.
   - `ghcr.io/<owner>/postgrest-db:latest` — only applied for full (non-pre) releases.
4. **Build and push** — builds from `postgrest-tandem/image/Containerfile` with `IMAGE_VERSION`, `VCS_REF` (full commit SHA), `SOURCE_URL`, and `POSTGRES_BASE_TAG=16` baked in as OCI labels, then pushes to GHCR.

To publish a new version, create and publish a GitHub release whose tag follows semver (e.g. `v1.2.3`). Pre-releases (marked as pre-release on GitHub) receive only the version tag; stable releases additionally move the `latest` tag.

## Notes

- JWTs are signed (tamper-proof), not encrypted (readable by holder).
- Keep `postgrest.jwt_secret` private and rotate periodically.
- Existing tokens become invalid immediately after secret rotation.

## Upstream Attribution

This image is based on the official PostgreSQL container image (`postgres`) and includes PostgreSQL software distributed under the PostgreSQL License.

- Official PostgreSQL license: https://www.postgresql.org/about/licence/
- Official Postgres container image: https://hub.docker.com/_/postgres
