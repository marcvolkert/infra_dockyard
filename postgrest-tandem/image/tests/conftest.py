"""Pytest fixtures and harness for PostgREST integration tests."""

import base64
import json
import os
import shutil
import subprocess
import time
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime

import pytest


@dataclass
class CommandResult:
    """Captured result from a subprocess command."""

    returncode: int
    stdout: str
    stderr: str

    @property
    def output(self) -> str:
        """Return combined stdout/stderr for assertion messages."""
        return "\n".join(part for part in (self.stdout, self.stderr) if part).strip()


def decode_jwt_payload(token: str) -> dict[str, object]:
    """Decode and parse the JWT payload segment as JSON."""
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(f"malformed token: expected 3 parts, got {len(parts)}")
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))


class PostgrestTestHarness:
    """Utility wrapper for container lifecycle and database test commands."""

    def __init__(self) -> None:
        """Initialize runtime, credentials, and image settings for tests."""
        self.container_name = "postgrest-db-pytest"
        self.port = os.environ.get("POSTGREST_DB_PORT", "5432")
        self.postgres_password = os.environ.get("POSTGRES_PASSWORD", "postgres-ci-only")
        self.authenticator_password = os.environ.get("AUTHENTICATOR_PASSWORD", "testpw-ci-only")
        self.test_image = os.environ.get("TEST_IMAGE", "local/postgrest-db:ci")
        self.container_runtime = os.environ.get("CONTAINER_RUNTIME", "podman")

    def ctr(self, *args: str) -> CommandResult:
        """Run a container-runtime command and return its captured output."""
        if shutil.which(self.container_runtime) is None:
            pytest.fail(f"container runtime not found: {self.container_runtime}")
        return self._run((self.container_runtime, *args))

    def _run(self, args: tuple[str, ...], env: dict[str, str] | None = None) -> CommandResult:
        """Execute a subprocess and normalize outputs into CommandResult."""
        result = subprocess.run(args, capture_output=True, text=True, env=env, check=False)
        return CommandResult(
            returncode=result.returncode,
            stdout=result.stdout.strip(),
            stderr=result.stderr.strip(),
        )

    def _psql(self, user: str, password: str, sql: str, *, stop_on_error: bool) -> CommandResult:
        """Execute SQL via psql against the test database as the given user."""
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        args = ["psql", "-X", "-qAt"]
        if stop_on_error:
            args.extend(["-v", "ON_ERROR_STOP=1"])
        args.extend(["-h", "127.0.0.1", "-p", self.port, "-U", user, "-d", "postgres", "-c", sql])
        return self._run(tuple(args), env=env)

    def psql_super(self, sql: str) -> CommandResult:
        """Run SQL as postgres with ON_ERROR_STOP enabled."""
        return self._psql("postgres", self.postgres_password, sql, stop_on_error=True)

    def psql_super_raw(self, sql: str) -> CommandResult:
        """Run SQL as postgres without ON_ERROR_STOP for negative tests."""
        return self._psql("postgres", self.postgres_password, sql, stop_on_error=False)

    def psql_authenticator(self, sql: str) -> CommandResult:
        """Run SQL as authenticator with ON_ERROR_STOP enabled."""
        return self._psql("authenticator", self.authenticator_password, sql, stop_on_error=True)

    def wait_for_postgres(self) -> bool:
        """Poll until PostgreSQL accepts connections or timeout is reached."""
        for _ in range(60):
            if self.psql_super("SELECT 1;").returncode == 0:
                return True
            time.sleep(1)
        return False

    def start_postgrest_db(self) -> None:
        """Start a fresh test container and wait for database readiness."""
        self.stop_postgrest_db()
        result = self.ctr(
            "run",
            "-d",
            "--name",
            self.container_name,
            "-p",
            f"{self.port}:5432",
            "-e",
            f"POSTGRES_PASSWORD={self.postgres_password}",
            "-e",
            f"AUTHENTICATOR_PASSWORD={self.authenticator_password}",
            self.test_image,
        )
        assert result.returncode == 0, result.output

        if not self.wait_for_postgres():
            logs = self.ctr("logs", self.container_name)
            pytest.fail(f"database did not become ready\n{logs.output}")

    def stop_postgrest_db(self) -> None:
        """Remove the test container if it exists."""
        self.ctr("rm", "-f", self.container_name)

    def ensure_alice_user(self) -> None:
        """Upsert a known alice test user with anon role."""
        result = self.psql_super(
            """
            DO $$
            BEGIN
                IF EXISTS (SELECT FROM auth.users WHERE username = 'alice') THEN
                    UPDATE auth.users
                      SET password = 'correct-password',
                          role = 'anon'
                      WHERE username = 'alice';
                ELSE
                    INSERT INTO auth.users (username, password, role)
                      VALUES ('alice', 'correct-password', 'anon');
                END IF;
            END $$;
            """
        )
        assert result.returncode == 0, result.output

    def jwt_secret_row(self) -> tuple[str, datetime]:
        """Fetch the current JWT secret and its last-updated timestamp."""
        result = self.psql_super("SELECT secret, updated_at FROM postgrest.jwt_secret LIMIT 1;")
        assert result.returncode == 0, result.output
        secret, updated_at = result.stdout.split("|", 1)
        return secret, datetime.fromisoformat(updated_at)


@pytest.fixture(scope="module")
def postgrest_db() -> Iterator[PostgrestTestHarness]:
    """Start one test database container per module and tear it down."""
    harness = PostgrestTestHarness()
    harness.start_postgrest_db()
    try:
        yield harness
    finally:
        harness.stop_postgrest_db()


@pytest.fixture
def alice_user(postgrest_db: PostgrestTestHarness) -> PostgrestTestHarness:
    """Ensure a known alice user exists before each dependent test."""
    postgrest_db.ensure_alice_user()
    return postgrest_db
