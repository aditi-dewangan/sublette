"""Shared fixtures.

Tests run against a real PostgreSQL database named sublette_test. Start it with
`make db` from the repository root, or point SUBLETTE_TEST_DATABASE_URL at one.
"""

import os
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

from app.config import Settings
from app.main import create_app

REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_ROOT = REPO_ROOT / "backend"

TEST_DATABASE_URL = os.environ.get(
    "SUBLETTE_TEST_DATABASE_URL",
    "postgresql+psycopg://sublette:sublette@localhost:5432/sublette_test",
)

# Nothing listens on port 1, so connections are refused at once. This stands in
# for "the database is down".
UNREACHABLE_DATABASE_URL = "postgresql+psycopg://sublette:sublette@127.0.0.1:1/sublette_test"


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


@pytest.fixture
def settings(database_url: str) -> Settings:
    return Settings(env="test", database_url=database_url)


@pytest.fixture
def app(settings: Settings) -> FastAPI:
    return create_app(settings)


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


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
