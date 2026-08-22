# PostgREST-Ready PostgreSQL Image

PostgreSQL image for PostgREST-backed workloads.

## Table of Contents

- [Concepts](#concepts)
  - [Files](#files)
  - [Init order](#init-order)
  - [How this image interacts with PostgREST](#how-this-image-interacts-with-postgrest)
    - [Roles](#roles)
    - [Schemas](#schemas)
    - [JWT secret lifecycle](#jwt-secret-lifecycle)
    - [Login flow](#login-flow)
    - [Wiring PostgREST to this database](#wiring-postgrest-to-this-database)
  - [Notes](#notes)
- [Usage](#usage)
  - [Build](#build)
  - [Run](#run)
  - [Smoke test](#smoke-test)
  - [Local integration tests (pytest)](#local-integration-tests-pytest)
    - [Run locally](#run-locally)
  - [CI/CD](#cicd)
    - [`test-postgrest-db` — integration tests on pull requests](#test-postgrest-db--integration-tests-on-pull-requests)
    - [`publish-postgrest-db` — image publish on release](#publish-postgrest-db--image-publish-on-release)
- [Upstream Attribution](#upstream-attribution)

Key features: database-managed JWT secret, built-in auth/login RPC bootstrap, password hashing with pgcrypto, and plpython-based JWT signing without pgjwt.

For more information, see the official PostgREST docs: https://postgrest.org/en/stable/

Note: commands below use `podman`; using `docker` should work by replacing the binary name.

## Concepts

### Files

- `Containerfile`: Postgres base image plus runtime dependency (`plpython3u`).
- `initdb/`: bootstrap scripts executed on first database initialization.

### Init order

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

### How this image interacts with PostgREST

This image is not a generic Postgres database — it is pre-wired so PostgREST can
connect, authenticate requests, and mint/verify JWTs without any external
identity provider or config-file secret. All of the moving parts below are
created by the `initdb/` scripts during first boot.

#### Roles

- **`authenticator`** — the only role PostgREST connects to the database as
  (`AUTHENTICATOR_PASSWORD`). It is `NOINHERIT LOGIN`, so it has no privileges
  of its own beyond what's explicitly granted; it must `SET ROLE` into a
  request role (e.g. `anon`) before running any query on behalf of a client.
- **`anon`** — the role PostgREST switches into for unauthenticated requests.
  It is `NOLOGIN` (never connects directly) and is only reachable via
  `GRANT anon TO authenticator`.
- Authenticated end users never get their own Postgres role. Instead, their
  privileges are encoded as a `role` claim inside a signed JWT, and PostgREST
  performs `SET ROLE <claim>` for the duration of that request.

#### Schemas

- **`api`** — the public-facing schema PostgREST exposes as the REST API
  surface (e.g. via `db-schemas` in PostgREST's config). It currently exposes
  `api.login`, granted to `anon` only.
- **`auth`** — internal, not exposed to PostgREST. Holds `auth.users`
  (bcrypt-hashed passwords, per-user `role` claim) and the `auth.login` /
  `auth.sign_jwt` functions that actually verify credentials and issue tokens.
- **`postgrest`** — internal, not exposed to PostgREST. Holds the JWT secret
  singleton (`postgrest.jwt_secret`) and the `postgrest.pre_config()` /
  `postgrest.rotate_jwt_secret()` functions.

#### JWT secret lifecycle

The signing secret lives in the database instead of a static config value:

1. On first boot, `postgrest.rotate_jwt_secret()` generates a random secret
   and stores it (as a singleton row) in `postgrest.jwt_secret`.
2. PostgREST calls `postgrest.pre_config()` (via `db-pre-config` in its
   config) on startup/config reload, which reads the current secret into
   `pgrst.jwt_secret` for that session — PostgREST then uses it to verify
   incoming bearer tokens.
3. `auth.sign_jwt()` (called from `auth.login`) reads the same secret to sign
   new tokens, so issuance and verification always stay in sync.
4. Rotating the secret (`SELECT postgrest.rotate_jwt_secret();`) immediately
   invalidates all previously issued tokens; only a superuser can call it.

#### Login flow

1. A client `POST`s credentials to PostgREST's `rpc/login` endpoint, which
   PostgREST maps to `api.login(username, password)`.
2. `api.login` is `SECURITY DEFINER` and granted to `anon` only, so an
   unauthenticated PostgREST request (running as `anon`) can call it, but
   nothing else in `auth`/`postgrest` is reachable directly.
3. `api.login` delegates to `auth.login`, which checks the bcrypt hash in
   `auth.users`, raises `invalid_password` (SQLSTATE `28P01`) on mismatch, and
   otherwise calls `auth.sign_jwt` to build a token with the user's `role`
   claim and a 15-minute expiry.
4. The client uses the returned token as a Bearer token on subsequent
   requests; PostgREST verifies it against `pgrst.jwt_secret` and
   `SET ROLE`s into the claimed role for that request only.

#### Wiring PostgREST to this database

At minimum, PostgREST needs to connect as `authenticator` and know where to
find the pre-config hook and exposed schema:

```
db-uri = "postgres://authenticator:<AUTHENTICATOR_PASSWORD>@<host>:5432/postgres"
db-schemas = "api"
db-anon-role = "anon"
db-pre-config = "postgrest.pre_config"
```

No `jwt-secret` config value is needed — it's supplied at runtime by
`postgrest.pre_config()` reading from `postgrest.jwt_secret`.

### Notes

- JWTs are signed (tamper-proof), not encrypted (readable by holder).
- Keep `postgrest.jwt_secret` private and rotate periodically.
- Existing tokens become invalid immediately after secret rotation.

## Usage

### Build

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

### Run

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

### Smoke test

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

### Local integration tests (pytest)

The integration suite under `postgrest-tandem/image/tests/` validates bootstrap scripts, auth/JWT behavior, and privilege boundaries directly via `psql`.

#### Run locally

From the repository root:

Create a virtual environment, install the test dependency, then run pytest:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r postgrest-tandem/image/tests/requirements.txt
pytest postgrest-tandem/image/tests/ -v
```

Notes:

- The test harness uses a fixed dummy credential (`AUTHENTICATOR_PASSWORD=testpw-ci-only`) for CI/local testing only.
- Tests require `psql` plus `podman` or `docker` on your PATH.
- Tests start and remove their own temporary database container.

### CI/CD

Two workflows ship with this repository, both located under `.github/workflows/`.

#### `test-postgrest-db` — integration tests on pull requests

**Trigger:** any pull request that targets `dev` or `main` and touches a file inside `postgrest-tandem/**`.

**Jobs (sequential):**

1. **build** — builds the image with `docker/build-push-action` and exports it as a `.tar` artifact (`postgrest-db-image`).
2. **integration-test** — downloads the artifact, loads it with `docker load`, creates a temporary Python virtualenv, installs test dependencies from `postgrest-tandem/image/tests/requirements.txt`, and runs `pytest postgrest-tandem/image/tests/ -v` with `TEST_IMAGE=local/postgrest-db:ci`.

The workflow uses the same image tag (`local/postgrest-db:ci`) and the same dummy credentials (`AUTHENTICATOR_PASSWORD=testpw-ci-only`) as the local test instructions above.

#### `publish-postgrest-db` — image publish on release

**Trigger:** a GitHub release is published (i.e. the `published` release event). Works for both full releases and pre-releases.

**Steps:**

1. **Determine release channel** — strips the leading `v` from the tag name and sets `channel=release` (or `prerelease` for pre-releases).
2. **Log in to GHCR** — authenticates with `secrets.GITHUB_TOKEN` (no additional secrets needed).
3. **Extract Docker metadata** — builds the tag list:
   - `ghcr.io/<owner>/postgrest-db:<version>` — always applied.
   - `ghcr.io/<owner>/postgrest-db:latest` — only applied for full (non-pre) releases.
4. **Build and push** — builds from `postgrest-tandem/image/Containerfile` with `IMAGE_VERSION`, `VCS_REF` (full commit SHA), `SOURCE_URL`, and `POSTGRES_BASE_TAG=16` baked in as OCI labels, then pushes to GHCR.

To publish a new version, create and publish a GitHub release whose tag follows semver (e.g. `v1.2.3`). Pre-releases (marked as pre-release on GitHub) receive only the version tag; stable releases additionally move the `latest` tag.

## Upstream Attribution

This image is based on the official PostgreSQL container image (`postgres`) and includes PostgreSQL software distributed under the PostgreSQL License.

- Official PostgreSQL license: https://www.postgresql.org/about/licence/
- Official Postgres container image: https://hub.docker.com/_/postgres
