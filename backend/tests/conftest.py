"""Shared fixtures.

Tests run against a real PostgreSQL database named sublette_test. Start it with
`make db` from the repository root, or point SUBLETTE_TEST_DATABASE_URL at one.
"""

import base64
import os
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from alembic.command import upgrade
from alembic.config import Config
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.config import Settings
from app.deps import get_now
from app.main import create_app
from app.routers.admin import form_token
from app.services.email_sender import EmailUnavailable
from app.services.schools import seed_schools

REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_ROOT = REPO_ROOT / "backend"

TEST_DATABASE_URL = os.environ.get(
    "SUBLETTE_TEST_DATABASE_URL",
    "postgresql+psycopg://sublette:sublette@localhost:5432/sublette_test",
)

# Nothing listens on port 1, so connections are refused at once. This stands in
# for "the database is down".
UNREACHABLE_DATABASE_URL = "postgresql+psycopg://sublette:sublette@127.0.0.1:1/sublette_test"

DATA_TABLES = (
    "assistant_queries, events, crash_reports, reports, blocks, uploads, messages, "
    "device_tokens, matches, swipes, saved_listings, renter_profiles, listing_photos, "
    "listings, stored_files, users, email_codes, rate_limit_hits, school_domains, schools"
)


def alembic_config(database_url: str) -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    config.attributes["configure_logging"] = False
    return config


@pytest.fixture(autouse=True)
def _no_ambient_settings(monkeypatch: pytest.MonkeyPatch) -> None:
    """Tests must not depend on the developer's own SUBLETTE_* variables, nor
    on the backend/.env file that holds them (a real Brevo key there once made
    "a key is required" pass without one)."""
    for name in list(os.environ):
        if name.startswith("SUBLETTE_") and name != "SUBLETTE_TEST_DATABASE_URL":
            monkeypatch.delenv(name)
    monkeypatch.setitem(Settings.model_config, "env_file", None)


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return REPO_ROOT


@pytest.fixture(scope="session")
def database_url() -> str:
    """The test database URL, after checking the database is really there.

    Fails (rather than skips) when it is not: a skipped test proves nothing.
    """
    settings = Settings(env="test", database_url=TEST_DATABASE_URL)
    engine = create_engine(settings.database_url, connect_args={"connect_timeout": 3})
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
    except SQLAlchemyError as error:
        pytest.fail(
            "The test database is not reachable. Run `make db` from the repository "
            f"root, or set SUBLETTE_TEST_DATABASE_URL. ({type(error).__name__})",
            pytrace=False,
        )
    finally:
        engine.dispose()
    return settings.database_url


@pytest.fixture(scope="session")
def migrated_database(database_url: str) -> str:
    """The test database with every migration applied. Done once per run;
    tests/test_migrations.py always leaves it back at head."""
    upgrade(alembic_config(database_url), "head")
    return database_url


@pytest.fixture
def clean_database(migrated_database: str) -> str:
    """The migrated test database with only the seed data in it."""
    database_url = migrated_database
    engine = create_engine(database_url)
    with Session(engine) as session:
        session.execute(text(f"TRUNCATE {DATA_TABLES} RESTART IDENTITY CASCADE"))
        seed_schools(session)
        session.commit()
    engine.dispose()
    return database_url


@pytest.fixture
def settings(clean_database: str, tmp_path: Path) -> Settings:
    return Settings(
        env="test",
        database_url=clean_database,
        storage_local_dir=str(tmp_path / "storage"),
        public_base_url="http://testserver",
    )


class Clock:
    """A clock the test controls."""

    def __init__(self) -> None:
        self.now = datetime(2027, 1, 4, 17, 0, tzinfo=UTC)

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


class RecordingMailer:
    """Stands in for the email provider. Remembers codes; can be switched off."""

    def __init__(self) -> None:
        self.sent: list[tuple[str, str]] = []
        self.down = False

    def send_code(self, to: str, code: str, ttl_minutes: int) -> None:
        if self.down:
            raise EmailUnavailable("provider is down")
        self.sent.append((to, code))

    def code_for(self, email: str) -> str:
        return next(code for to, code in reversed(self.sent) if to == email.lower())


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def mailer() -> RecordingMailer:
    return RecordingMailer()


@pytest.fixture
def app(settings: Settings, clock: Clock, mailer: RecordingMailer) -> FastAPI:
    application = create_app(settings)
    application.state.email_sender = mailer
    application.dependency_overrides[get_now] = lambda: clock.now
    return application


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def db(app: FastAPI) -> Iterator[Session]:
    """A session for looking at what the server wrote."""
    with Session(app.state.engine) as session:
        yield session


def sign_in(client: TestClient, mailer: RecordingMailer, email: str) -> dict:
    """Request a code, verify it, and return the response body (tokens and user)."""
    response = client.post("/v1/auth/request-code", json={"email": email})
    assert response.status_code == 200, response.text
    response = client.post("/v1/auth/verify", json={"email": email, "code": mailer.code_for(email)})
    assert response.status_code == 200, response.text
    return response.json()


def bearer(session_body: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {session_body['access_token']}"}


@pytest.fixture
def aditi(client: TestClient, mailer: RecordingMailer) -> dict:
    """A signed-in UW student: tokens and user."""
    return sign_in(client, mailer, "aditi@uw.edu")


@pytest.fixture
def app_without_database() -> FastAPI:
    """The app, configured with a database that refuses every connection."""
    return create_app(
        Settings(env="test", database_url=UNREACHABLE_DATABASE_URL, db_connect_timeout_s=1)
    )


@pytest.fixture
def client_without_database(app_without_database: FastAPI) -> Iterator[TestClient]:
    with TestClient(app_without_database) as test_client:
        yield test_client


ADMIN_PASSWORD = "correct horse battery staple"


def settings_with(app: FastAPI, **changes) -> Settings:
    app.state.settings = app.state.settings.model_copy(update=changes)
    return app.state.settings


@pytest.fixture
def admin(app: FastAPI) -> dict[str, str]:
    """Turns the admin page on; returns the browser's sign-in header."""
    settings_with(app, admin_password=ADMIN_PASSWORD)
    return {
        "Authorization": "Basic " + base64.b64encode(f"admin:{ADMIN_PASSWORD}".encode()).decode()
    }


def admin_post(client: TestClient, app: FastAPI, admin: dict, path: str, **fields):
    data = {"token": form_token(app.state.settings), **fields}
    return client.post(path, headers=admin, data=data, follow_redirects=False)
