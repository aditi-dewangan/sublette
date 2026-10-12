"""GET /health: version, database reachability, and behaviour when the database is down."""

import time

import pytest
from fastapi.testclient import TestClient

from app import __version__
from app.db import make_engine
from tests.conftest import UNREACHABLE_DATABASE_URL


def test_health_reports_version_and_reachable_database(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == __version__
    assert body["environment"] == "test"
    assert body["database"]["reachable"] is True
    assert "code" not in body
    assert "message" not in body


def test_health_version_is_a_real_version(client: TestClient) -> None:
    version = client.get("/health").json()["version"]

    assert version[0].isdigit()
    assert "unknown" not in version


def test_health_is_never_cached(client: TestClient) -> None:
    assert client.get("/health").headers["cache-control"] == "no-store"


# --- Dependency unavailable: the database -----------------------------------


def test_app_starts_when_the_database_is_down(client_without_database: TestClient) -> None:
    # Entering the client fixture ran startup. Reaching this line is the test.
    assert client_without_database.app is not None


def test_health_returns_503_when_the_database_is_down(
    client_without_database: TestClient,
) -> None:
    response = client_without_database.get("/health")

    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "degraded"
    assert body["version"] == __version__
    assert body["database"] == {"reachable": False}
    # Also readable as the standard {code, message} error shape.
    assert body["code"] == "database_unreachable"
    assert body["message"]


def test_health_answers_quickly_when_the_database_is_down(
    client_without_database: TestClient,
) -> None:
    started = time.monotonic()
    client_without_database.get("/health")

    assert time.monotonic() - started < 5


def test_health_does_not_leak_connection_details(
    client_without_database: TestClient,
) -> None:
    text = client_without_database.get("/health").text

    for secret in ("127.0.0.1", "sublette:sublette", "psycopg", "Traceback"):
        assert secret not in text


def test_other_routes_still_answer_when_the_database_is_down(
    client_without_database: TestClient,
) -> None:
    response = client_without_database.get("/v1/does-not-exist")

    assert response.status_code == 404
    assert response.json()["code"] == "not_found"


@pytest.mark.parametrize(
    ("method", "path", "body"),
    [
        ("POST", "/v1/auth/request-code", {"email": "aditi@uw.edu"}),
        ("POST", "/v1/auth/verify", {"email": "aditi@uw.edu", "code": "123456"}),
    ],
)
def test_sign_in_says_try_again_when_the_database_is_down(
    client_without_database: TestClient, method: str, path: str, body: dict
) -> None:
    response = client_without_database.request(method, path, json=body)

    assert response.status_code == 503
    assert response.json() == {
        "code": "service_unavailable",
        "message": "Sublette is having trouble right now. Try again in a minute.",
    }
    assert response.headers["Retry-After"] == "30"
    assert "127.0.0.1" not in response.text


def test_a_signed_in_request_says_try_again_when_the_database_is_down(app, aditi, settings) -> None:
    from tests.conftest import bearer

    app.state.engine = make_engine(
        settings.model_copy(
            update={"database_url": UNREACHABLE_DATABASE_URL, "db_connect_timeout_s": 1}
        )
    )
    with TestClient(app) as client:
        response = client.get("/v1/me", headers=bearer(aditi))

    assert response.status_code == 503
    assert response.json()["code"] == "service_unavailable"


def test_health_recovers_after_the_database_goes_down_and_comes_back(app, settings) -> None:
    healthy_engine = app.state.engine
    with TestClient(app) as client:
        assert client.get("/health").status_code == 200

        # The database goes away while the server is running.
        app.state.engine = make_engine(
            settings.model_copy(
                update={"database_url": UNREACHABLE_DATABASE_URL, "db_connect_timeout_s": 1}
            )
        )
        assert client.get("/health").status_code == 503

        # It comes back; no restart needed.
        app.state.engine = healthy_engine
        assert client.get("/health").status_code == 200
