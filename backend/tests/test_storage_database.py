"""Photos kept in the database: the $0 staging setup, where the disk is wiped on restart."""

from urllib.parse import urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import Settings
from app.deps import get_now
from app.main import create_app
from app.models import StoredFile
from tests.conftest import Clock, RecordingMailer, bearer, sign_in

JPEG = b"\xff\xd8\xff\xe0" + b"stored-in-the-database" * 30


@pytest.fixture
def database_app(settings, clock: Clock, mailer: RecordingMailer) -> FastAPI:
    app = create_app(settings.model_copy(update={"storage_backend": "database"}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    return app


def upload(client: TestClient, who: dict) -> dict:
    link = client.post(
        "/v1/uploads/presign",
        headers=bearer(who),
        json={"purpose": "profile_photo", "content_type": "image/jpeg"},
    ).json()
    parts = urlsplit(link["upload_url"])
    response = client.put(f"{parts.path}?{parts.query}", content=JPEG, headers=link["headers"])
    assert response.status_code == 204, response.text
    return link


def test_a_photo_goes_into_the_database_and_comes_back(
    database_app: FastAPI, mailer: RecordingMailer, settings, tmp_path
) -> None:
    with TestClient(database_app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = upload(client, who)
        served = client.get(urlsplit(link["public_url"]).path)

    assert served.status_code == 200
    assert served.content == JPEG
    assert served.headers["content-type"] == "image/jpeg"
    assert "immutable" in served.headers["cache-control"]
    with Session(database_app.state.engine) as session:
        row = session.get(StoredFile, link["key"])
        assert row is not None and row.size == len(JPEG)
    # Nothing was written to disk.
    assert not (tmp_path / "storage").exists()


def test_photos_survive_a_restart_with_an_empty_disk(
    database_app: FastAPI, mailer: RecordingMailer, settings, clock: Clock
) -> None:
    with TestClient(database_app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = upload(client, who)

    restarted = create_app(settings.model_copy(update={"storage_backend": "database"}))
    with TestClient(restarted) as client:
        assert client.get(urlsplit(link["public_url"]).path).content == JPEG


def test_replacing_a_profile_photo_deletes_the_old_row(
    database_app: FastAPI, mailer: RecordingMailer
) -> None:
    with TestClient(database_app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        first = upload(client, who)
        client.patch("/v1/me", headers=bearer(who), json={"photo_key": first["key"]})
        second = upload(client, who)
        client.patch("/v1/me", headers=bearer(who), json={"photo_key": second["key"]})

        assert client.get(urlsplit(first["public_url"]).path).status_code == 404

    with Session(database_app.state.engine) as session:
        assert session.scalar(select(func.count()).select_from(StoredFile)) == 1


def test_the_upload_rules_are_the_same_as_for_a_folder(
    database_app: FastAPI, mailer: RecordingMailer, clock: Clock
) -> None:
    with TestClient(database_app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = client.post(
            "/v1/uploads/presign",
            headers=bearer(who),
            json={"purpose": "profile_photo", "content_type": "image/jpeg"},
        ).json()
        parts = urlsplit(link["upload_url"])
        wrong_type = client.put(
            f"{parts.path}?{parts.query}", content=JPEG, headers={"Content-Type": "image/png"}
        )
        clock.advance(minutes=11)
        expired = client.put(f"{parts.path}?{parts.query}", content=JPEG, headers=link["headers"])

    assert wrong_type.status_code == 403
    assert expired.status_code == 403


def test_reading_a_photo_says_try_again_when_the_database_is_down(
    database_app: FastAPI, mailer: RecordingMailer, settings
) -> None:
    from app.db import make_engine
    from app.services.storage import DatabaseStore
    from tests.conftest import UNREACHABLE_DATABASE_URL

    with TestClient(database_app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = upload(client, who)
        database_app.state.storage.store = DatabaseStore(
            make_engine(
                settings.model_copy(
                    update={"database_url": UNREACHABLE_DATABASE_URL, "db_connect_timeout_s": 1}
                )
            )
        )
        response = client.get(urlsplit(link["public_url"]).path)

    assert response.status_code == 503
    assert response.json()["code"] == "service_unavailable"


# --- The server's own address -------------------------------------------------


def test_on_render_the_public_address_is_filled_in_automatically(monkeypatch) -> None:
    monkeypatch.setenv("RENDER_EXTERNAL_URL", "https://sublette-staging.onrender.com")

    assert Settings().public_base_url == "https://sublette-staging.onrender.com"


def test_an_explicit_public_address_wins_over_renders(monkeypatch) -> None:
    monkeypatch.setenv("RENDER_EXTERNAL_URL", "https://sublette-staging.onrender.com")
    monkeypatch.setenv("SUBLETTE_PUBLIC_BASE_URL", "https://api.sublette.example/")

    assert Settings().public_base_url == "https://api.sublette.example"
