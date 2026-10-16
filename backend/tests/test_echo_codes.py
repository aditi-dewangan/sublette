"""Development: sign-in codes are printed in the terminal as well as emailed."""

import logging
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app.config import Settings
from app.deps import get_now
from app.main import create_app
from tests.conftest import Clock, RecordingMailer


def local_settings(database_url: str, tmp_path: Path, **changes) -> Settings:
    values = dict(
        env="local",
        database_url=database_url,
        email_backend="smtp",
        smtp_host="smtp.example.test",
        storage_local_dir=str(tmp_path / "storage"),
        public_base_url="http://testserver",
    )
    values.update(changes)
    return Settings(**values)


@pytest.fixture
def make_client(clean_database: str, tmp_path: Path, mailer: RecordingMailer, clock: Clock):
    clients = []

    def build(**changes) -> TestClient:
        app = create_app(local_settings(clean_database, tmp_path, **changes))
        app.state.email_sender = mailer
        app.dependency_overrides[get_now] = lambda: clock.now
        client = TestClient(app)
        client.__enter__()
        clients.append(client)
        return client

    yield build
    for client in clients:
        client.__exit__(None, None, None)


def ask(client: TestClient, email: str = "aditi@uw.edu"):
    return client.post("/v1/auth/request-code", json={"email": email})


def printed_code(caplog: pytest.LogCaptureFixture) -> str | None:
    for record in caplog.records:
        message = record.getMessage()
        if message.startswith("Sign-in code for aditi@uw.edu: "):
            return message.split(": ")[1].split()[0]
    return None


def test_a_local_server_emails_the_code_and_prints_it(
    make_client, mailer: RecordingMailer, caplog: pytest.LogCaptureFixture
) -> None:
    client = make_client()
    caplog.set_level(logging.WARNING, logger="sublette.auth")

    assert ask(client).status_code == 200

    assert mailer.sent == [("aditi@uw.edu", mailer.code_for("aditi@uw.edu"))]
    assert printed_code(caplog) == mailer.code_for("aditi@uw.edu")


def test_when_the_email_fails_locally_the_printed_code_still_works(
    make_client, mailer: RecordingMailer, caplog: pytest.LogCaptureFixture
) -> None:
    client = make_client()
    mailer.down = True
    caplog.set_level(logging.WARNING, logger="sublette.auth")

    assert ask(client).status_code == 200
    code = printed_code(caplog)
    assert code is not None
    assert any("failed" in record.getMessage() for record in caplog.records)

    response = client.post("/v1/auth/verify", json={"email": "aditi@uw.edu", "code": code})
    assert response.status_code == 200, response.text


def test_printing_can_be_turned_off(
    make_client, mailer: RecordingMailer, caplog: pytest.LogCaptureFixture
) -> None:
    client = make_client(email_echo_codes=False)
    caplog.set_level(logging.WARNING, logger="sublette.auth")

    assert ask(client).status_code == 200
    assert printed_code(caplog) is None

    mailer.down = True
    client2 = make_client(email_echo_codes=False)
    assert ask(client2, "sam@uw.edu").status_code == 503


@pytest.mark.parametrize(
    ("env", "expected"), [("local", True), ("test", False), ("staging", False)]
)
def test_printing_is_on_by_default_only_on_a_local_server(env: str, expected: bool) -> None:
    settings = Settings.model_construct(env=env, email_echo_codes=None)

    assert settings.echo_codes is expected


def test_production_refuses_to_print_codes() -> None:
    with pytest.raises(ValidationError, match="SUBLETTE_EMAIL_ECHO_CODES"):
        Settings(
            env="production",
            email_echo_codes=True,
            secret_key="x" * 40,
            email_backend="smtp",
            smtp_host="smtp.example.test",
            storage_backend="none",
        )


def test_production_never_prints_by_default() -> None:
    assert Settings.model_construct(env="production", email_echo_codes=None).echo_codes is False
