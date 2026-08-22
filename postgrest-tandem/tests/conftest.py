import base64
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Iterator

import pytest


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def output(self) -> str:
        return "\n".join(part for part in (self.stdout, self.stderr) if part).strip()


class PostgrestTestHarness:
    def __init__(self) -> None:
        self.container_name = "postgrest-db-pytest"
        self.port = os.environ.get("POSTGREST_DB_PORT", "55432")
        self.postgres_password = os.environ.get("POSTGRES_PASSWORD", "postgres-ci-only")
        self.authenticator_password = os.environ.get("AUTHENTICATOR_PASSWORD", "testpw-ci-only")
        self.test_image = os.environ.get("TEST_IMAGE", "local/postgrest-db:ci")
        self.container_runtime = os.environ.get("CONTAINER_RUNTIME", "podman")

    def ctr(self, *args: str) -> CommandResult:
        if shutil.which(self.container_runtime) is None:
            pytest.fail(f"container runtime not found: {self.container_runtime}")
        return self._run((self.container_runtime, *args))

    def _run(self, args: tuple[str, ...], env: dict[str, str] | None = None) -> CommandResult:
        result = subprocess.run(args, capture_output=True, text=True, env=env, check=False)
        return CommandResult(
            returncode=result.returncode,
            stdout=result.stdout.strip(),
            stderr=result.stderr.strip(),
        )

    def _psql(self, user: str, password: str, sql: str, *, stop_on_error: bool) -> CommandResult:
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        args = ["psql", "-X", "-qAt"]
        if stop_on_error:
            args.extend(["-v", "ON_ERROR_STOP=1"])
        args.extend(["-h", "127.0.0.1", "-p", self.port, "-U", user, "-d", "postgres", "-c", sql])
        return self._run(tuple(args), env=env)

    def psql_super(self, sql: str) -> CommandResult:
        return self._psql("postgres", self.postgres_password, sql, stop_on_error=True)

    def psql_super_raw(self, sql: str) -> CommandResult:
        return self._psql("postgres", self.postgres_password, sql, stop_on_error=False)

    def psql_authenticator(self, sql: str) -> CommandResult:
        return self._psql("authenticator", self.authenticator_password, sql, stop_on_error=True)

    def wait_for_postgres(self) -> bool:
        for _ in range(60):
            if self.psql_super("SELECT 1;").returncode == 0:
                return True
            time.sleep(1)
        return False

    def start_postgrest_db(self) -> None:
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
        self.ctr("rm", "-f", self.container_name)

    def ensure_alice_user(self) -> None:
        result = self.psql_super(
            """
            INSERT INTO auth.users (username, password, role)
            VALUES ('alice', 'correct-password', 'anon')
            ON CONFLICT (username) DO UPDATE
              SET password = EXCLUDED.password,
                  role = EXCLUDED.role;
            """
        )
        assert result.returncode == 0, result.output

    @staticmethod
    def decode_jwt_payload(token: str) -> dict[str, object]:
        parts = token.split(".")
        if len(parts) != 3:
            raise ValueError(f"malformed token: expected 3 parts, got {len(parts)}")
        payload = parts[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))

    @staticmethod
    def parse_secret_row(output: str) -> tuple[str, datetime]:
        secret, updated_at = output.split("|", 1)
        return secret, datetime.fromisoformat(updated_at)


@pytest.fixture(scope="module")
def postgrest_db() -> Iterator[PostgrestTestHarness]:
    harness = PostgrestTestHarness()
    harness.start_postgrest_db()
    try:
        yield harness
    finally:
        harness.stop_postgrest_db()


@pytest.fixture
def alice_user(postgrest_db: PostgrestTestHarness) -> PostgrestTestHarness:
    postgrest_db.ensure_alice_user()
    return postgrest_db
