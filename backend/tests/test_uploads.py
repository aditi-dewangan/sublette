"""Photo uploads: POST /v1/uploads/presign, the local dev storage, and S3 links."""

from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.deps import get_now
from app.main import create_app
from app.services.storage import (
    KEY_PATTERN,
    LocalStorage,
    NoStorage,
    S3Storage,
    StorageUnavailable,
    make_storage,
    new_key,
)
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_me import COMPLETE_PROFILE

JPEG = b"\xff\xd8\xff\xe0" + b"sublette-test-photo" * 50
PRESIGN = "/v1/uploads/presign"


def presign(client: TestClient, who: dict, purpose="profile_photo", content_type="image/jpeg"):
    return client.post(
        PRESIGN, headers=bearer(who), json={"purpose": purpose, "content_type": content_type}
    )


def path_of(url: str) -> str:
    """The part of an absolute URL the test client can request."""
    parts = urlsplit(url)
    return parts.path + (f"?{parts.query}" if parts.query else "")


def upload_photo(client: TestClient, who: dict, data: bytes = JPEG) -> dict:
    link = presign(client, who).json()
    response = client.put(path_of(link["upload_url"]), content=data, headers=link["headers"])
    assert response.status_code == 204, response.text
    return link


# --- Presign ------------------------------------------------------------------


def test_presign_returns_a_link_under_the_callers_own_folder(
    client: TestClient, aditi: dict, clock: Clock
) -> None:
    response = presign(client, aditi)

    assert response.status_code == 200
    body = response.json()
    assert KEY_PATTERN.match(body["key"])
    assert body["key"].startswith(f"profiles/{aditi['user']['id']}/")
    assert body["key"].endswith(".jpg")
    assert body["method"] == "PUT"
    assert body["headers"] == {"Content-Type": "image/jpeg"}
    assert body["upload_url"].startswith(f"http://testserver/dev-storage/{body['key']}?")
    assert body["public_url"] == f"http://testserver/dev-storage/{body['key']}"
    assert body["max_bytes"] == 10 * 1024 * 1024
    assert body["expires_at"].startswith("2027-01-04T17:10:00")


def test_listing_photos_get_their_own_folder(client: TestClient, aditi: dict) -> None:
    body = presign(client, aditi, purpose="listing_photo", content_type="image/png").json()

    assert body["key"].startswith(f"listings/{aditi['user']['id']}/")
    assert body["key"].endswith(".png")


def test_every_link_has_a_new_key(client: TestClient, aditi: dict) -> None:
    assert presign(client, aditi).json()["key"] != presign(client, aditi).json()["key"]


@pytest.mark.parametrize(
    "body",
    [
        {"purpose": "profile_photo", "content_type": "application/pdf"},
        {"purpose": "profile_photo", "content_type": "image/svg+xml"},
        {"purpose": "cover", "content_type": "image/jpeg"},
        {"purpose": "profile_photo"},
    ],
)
def test_only_photos_for_known_purposes_are_accepted(
    client: TestClient, aditi: dict, body: dict
) -> None:
    response = client.post(PRESIGN, headers=bearer(aditi), json=body)

    assert response.status_code == 422
    assert response.json()["code"] == "validation_error"


# --- Local storage round trip -------------------------------------------------


def test_a_photo_can_be_uploaded_and_read_back(client: TestClient, aditi: dict) -> None:
    link = upload_photo(client, aditi)

    served = client.get(path_of(link["public_url"]))

    assert served.status_code == 200
    assert served.content == JPEG
    assert served.headers["content-type"] == "image/jpeg"


def test_an_uploaded_photo_can_be_attached_to_the_profile(client: TestClient, aditi: dict) -> None:
    link = upload_photo(client, aditi)

    body = client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": link["key"]}).json()

    assert body["photo_url"] == link["public_url"]
    assert client.get("/v1/me", headers=bearer(aditi)).json()["photo_url"] == link["public_url"]


def test_replacing_or_removing_the_photo_deletes_the_old_file(
    client: TestClient, aditi: dict
) -> None:
    first = upload_photo(client, aditi)
    client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": first["key"]})
    second = upload_photo(client, aditi)

    client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": second["key"]})
    assert client.get(path_of(first["public_url"])).status_code == 404
    assert client.get(path_of(second["public_url"])).status_code == 200

    removed = client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": None}).json()
    assert removed["photo_url"] is None
    assert client.get(path_of(second["public_url"])).status_code == 404


def test_deleting_the_account_deletes_its_photo(client: TestClient, aditi: dict) -> None:
    link = upload_photo(client, aditi)
    client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": link["key"]})

    client.delete("/v1/me", headers=bearer(aditi))

    assert client.get(path_of(link["public_url"])).status_code == 404


def test_another_users_photo_cannot_be_attached(
    client: TestClient, mailer: RecordingMailer, aditi: dict
) -> None:
    sam = sign_in(client, mailer, "sam@northeastern.edu")
    sams_photo = upload_photo(client, sam)

    response = client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": sams_photo["key"]})

    assert response.status_code == 422
    assert response.json()["fields"][0]["field"] == "photo_key"


@pytest.mark.parametrize(
    "key",
    [
        "https://evil.example/tracker.jpg",
        "../../etc/passwd",
        "profiles/not-a-uuid/abc.jpg",
        "",
    ],
)
def test_only_a_real_storage_key_can_be_attached(client: TestClient, aditi: dict, key: str) -> None:
    response = client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": key})

    assert response.status_code == 422


def test_a_listing_photo_cannot_be_used_as_a_profile_photo(client: TestClient, aditi: dict) -> None:
    key = presign(client, aditi, purpose="listing_photo").json()["key"]

    response = client.patch("/v1/me", headers=bearer(aditi), json={"photo_key": key})

    assert response.status_code == 422


def test_an_upload_link_stops_working_after_ten_minutes(
    client: TestClient, aditi: dict, clock: Clock
) -> None:
    link = presign(client, aditi).json()
    clock.advance(minutes=10)

    response = client.put(path_of(link["upload_url"]), content=JPEG, headers=link["headers"])

    assert response.status_code == 403
    assert response.json()["code"] == "upload_link_invalid"


def test_an_upload_link_cannot_be_altered(client: TestClient, aditi: dict) -> None:
    link = presign(client, aditi).json()
    other_key = presign(client, aditi).json()["key"]
    url = path_of(link["upload_url"])

    wrong_signature = client.put(url[:-4] + "0000", content=JPEG, headers=link["headers"])
    wrong_type = client.put(url, content=JPEG, headers={"Content-Type": "image/png"})
    wrong_key = client.put(
        url.replace(link["key"], other_key), content=JPEG, headers=link["headers"]
    )
    later = url.replace(
        f"expires={parse_qs(urlsplit(url).query)['expires'][0]}", "expires=9999999999"
    )
    longer_life = client.put(later, content=JPEG, headers=link["headers"])

    for response in (wrong_signature, wrong_type, wrong_key, longer_life):
        assert response.status_code == 403
    assert client.get(path_of(link["public_url"])).status_code == 404


def test_a_photo_over_the_size_limit_is_refused(settings, clock, mailer: RecordingMailer) -> None:
    app = create_app(settings.model_copy(update={"upload_max_bytes": 1000}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = presign(client, who).json()
        response = client.put(
            path_of(link["upload_url"]), content=b"x" * 1001, headers=link["headers"]
        )
        assert response.status_code == 413
        assert response.json()["code"] == "file_too_large"
        assert client.get(path_of(link["public_url"])).status_code == 404


def test_an_empty_upload_is_refused(client: TestClient, aditi: dict) -> None:
    link = presign(client, aditi).json()

    response = client.put(path_of(link["upload_url"]), content=b"", headers=link["headers"])

    assert response.status_code == 400


@pytest.mark.parametrize(
    "path",
    [
        "/dev-storage/../../etc/passwd",
        "/dev-storage/profiles/../../secret.jpg",
        "/dev-storage/profiles/abc/def.jpg",
        "/dev-storage/nothing",
    ],
)
def test_storage_paths_cannot_escape_the_storage_folder(client: TestClient, path: str) -> None:
    assert client.get(path).status_code == 404
    assert client.put(f"{path}?expires=9999999999&signature=x", content=JPEG).status_code == 404


def test_local_storage_refuses_keys_outside_its_folder(settings) -> None:
    storage = LocalStorage(settings)

    with pytest.raises(ValueError):
        storage.path_for("../outside.jpg")
    storage.delete("../outside.jpg")  # logged, not raised


# --- Dependency unavailable: photo storage -----------------------------------


@pytest.fixture
def app_without_storage(settings, clock: Clock, mailer: RecordingMailer) -> FastAPI:
    app = create_app(settings.model_copy(update={"storage_backend": "none"}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    return app


def test_presign_says_so_clearly_when_storage_is_unavailable(
    app_without_storage: FastAPI, mailer: RecordingMailer
) -> None:
    with TestClient(app_without_storage) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        response = presign(client, who)

    assert response.status_code == 503
    assert response.json() == {
        "code": "uploads_unavailable",
        "message": "Photo uploads aren't available right now. You can add a photo later.",
    }


def test_sign_up_and_profile_still_work_without_storage(
    app_without_storage: FastAPI, mailer: RecordingMailer
) -> None:
    with TestClient(app_without_storage) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        body = client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE).json()
        assert body["profile_complete"] is True
        assert body["photo_url"] is None
        assert client.delete("/v1/me", headers=bearer(who)).status_code == 204


def test_a_profile_with_a_photo_still_loads_if_storage_is_later_switched_off(
    settings, clock: Clock, mailer: RecordingMailer
) -> None:
    app = create_app(settings)
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        link = upload_photo(client, who)
        client.patch("/v1/me", headers=bearer(who), json={"photo_key": link["key"]})

        app.state.storage = NoStorage()
        me = client.get("/v1/me", headers=bearer(who))

    assert me.status_code == 200
    assert me.json()["photo_url"] is None


def test_s3_presign_failure_becomes_storage_unavailable(settings, clock: Clock) -> None:
    storage = S3Storage(s3_settings(settings))

    def broken():
        raise RuntimeError("boto3 could not be loaded")

    storage._s3 = broken

    with pytest.raises(StorageUnavailable):
        storage.presign_upload("profiles/x/y.jpg", "image/jpeg", clock.now)
    storage.delete("profiles/x/y.jpg")  # logged, not raised


# --- S3-compatible storage ----------------------------------------------------


def s3_settings(settings):
    return settings.model_copy(
        update={
            "storage_backend": "s3",
            "s3_bucket": "sublette-photos",
            "s3_region": "us-west-2",
            "s3_access_key_id": "AKIAEXAMPLE",
            "s3_secret_access_key": "example-secret",
            "s3_public_base_url": "https://photos.example.test",
        }
    )


def test_the_backend_follows_the_setting(settings, tmp_path: Path) -> None:
    assert isinstance(make_storage(settings), LocalStorage)
    assert isinstance(make_storage(s3_settings(settings)), S3Storage)
    assert isinstance(
        make_storage(settings.model_copy(update={"storage_backend": "none"})), NoStorage
    )


def test_s3_link_is_signed_for_one_key_one_content_type_and_ten_minutes(
    settings, clock: Clock
) -> None:
    storage = S3Storage(s3_settings(settings))
    key = new_key("profile_photo", "3c4f52d8-8b8f-4ae8-b342-a394b00a938c", "image/jpeg")

    upload = storage.presign_upload(key, "image/jpeg", clock.now)

    url = urlsplit(upload.upload_url)
    query = parse_qs(url.query)
    assert url.scheme == "https"
    assert "sublette-photos" in url.netloc + url.path
    assert url.path.endswith(key)
    assert query["X-Amz-Algorithm"] == ["AWS4-HMAC-SHA256"]
    assert query["X-Amz-Expires"] == ["600"]
    assert "content-type" in query["X-Amz-SignedHeaders"][0]
    assert query["X-Amz-Signature"][0]
    assert "example-secret" not in upload.upload_url
    assert upload.method == "PUT"
    assert upload.headers == {"Content-Type": "image/jpeg"}
    assert upload.public_url == f"https://photos.example.test/{key}"


def test_s3_custom_endpoint_is_used_for_other_providers(settings, clock: Clock) -> None:
    custom = s3_settings(settings).model_copy(
        update={"s3_endpoint_url": "https://account.r2.example.test", "s3_region": "auto"}
    )

    upload = S3Storage(custom).presign_upload("profiles/x/y.jpg", "image/jpeg", clock.now)

    assert upload.upload_url.startswith("https://account.r2.example.test/")


def test_with_s3_the_server_serves_no_storage_routes(settings) -> None:
    app = create_app(s3_settings(settings))

    assert not any(path.startswith("/dev-storage") for path in app.openapi()["paths"])
