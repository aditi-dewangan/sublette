"""The JSON the server really sends, kept as files the iPhone app's tests decode.

docs/contract/samples/*.json are read by both codebases:
  * here, each file must equal what the server returns today;
  * in ios/SubletteTests, the Swift models must decode each file.

So a renamed or retyped field fails here first, and once the sample is updated
it fails in the app until the Swift model follows.

To rewrite the samples after an intended API change:
    UPDATE_CONTRACT_SAMPLES=1 make test
"""

import json
import os
import re

from fastapi.testclient import TestClient

from tests.conftest import REPO_ROOT, RecordingMailer, bearer, sign_in
from tests.test_me import COMPLETE_PROFILE
from tests.test_uploads import upload_photo

SAMPLES = REPO_ROOT / "docs" / "contract" / "samples"

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
HEX32 = re.compile(r"\b[0-9a-f]{32}\b")
HEX64 = re.compile(r"\b[0-9a-f]{64}\b")
TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def normalize(value, key: str = ""):
    """Replace the parts that differ on every run with fixed stand-ins."""
    if isinstance(value, dict):
        return {name: normalize(item, name) for name, item in value.items()}
    if isinstance(value, list):
        return [normalize(item, key) for item in value]
    if isinstance(value, str):
        if key.endswith("_at"):
            assert TIME.match(value), f"{key} is not UTC to the second: {value}"
            return "2027-01-04T17:00:00Z"
        if key in ("access_token", "refresh_token"):
            return f"sample.{key}"
        value = UUID.sub("11111111-2222-4333-8444-555555555555", value)
        value = HEX64.sub("f" * 64, value)
        return HEX32.sub("a" * 32, value)
    return value


def check(name: str, actual) -> None:
    path = SAMPLES / f"{name}.json"
    normalized = normalize(actual)
    if os.environ.get("UPDATE_CONTRACT_SAMPLES"):
        path.write_text(json.dumps(normalized, indent=2) + "\n", encoding="utf-8")
    assert path.exists(), f"{path} is missing. Run with UPDATE_CONTRACT_SAMPLES=1 to create it."
    assert json.loads(path.read_text(encoding="utf-8")) == normalized


def test_request_code_sample(client: TestClient) -> None:
    check(
        "request_code", client.post("/v1/auth/request-code", json={"email": "aditi@uw.edu"}).json()
    )


def test_session_sample_for_a_new_user(client: TestClient, mailer: RecordingMailer) -> None:
    check("session_new_user", sign_in(client, mailer, "aditi@uw.edu"))


def test_tokens_sample(client: TestClient, aditi: dict) -> None:
    response = client.post("/v1/auth/refresh", json={"refresh_token": aditi["refresh_token"]})

    check("tokens", response.json())


def test_user_sample_with_a_complete_profile_and_photo(client: TestClient, aditi: dict) -> None:
    link = upload_photo(client, aditi)
    client.patch(
        "/v1/me",
        headers=bearer(aditi),
        json={**COMPLETE_PROFILE, "gender": "woman", "photo_key": link["key"]},
    )

    check("user_complete", client.get("/v1/me", headers=bearer(aditi)).json())


def test_presign_sample(client: TestClient, aditi: dict) -> None:
    response = client.post(
        "/v1/uploads/presign",
        headers=bearer(aditi),
        json={"purpose": "profile_photo", "content_type": "image/jpeg"},
    )

    check("presign", response.json())


def test_error_samples(client: TestClient, aditi: dict) -> None:
    check(
        "error_not_edu",
        client.post("/v1/auth/request-code", json={"email": "aditi@gmail.com"}).json(),
    )
    check(
        "error_code_invalid",
        client.post("/v1/auth/verify", json={"email": "sam@uw.edu", "code": "000000"}).json(),
    )
    check(
        "error_validation",
        client.patch("/v1/me", headers=bearer(aditi), json={"first_name": "", "year": "x"}).json(),
    )
    check("error_not_signed_in", client.get("/v1/me").json())


def test_every_time_in_the_samples_is_utc_to_the_second() -> None:
    def times(value, key=""):
        if isinstance(value, dict):
            for name, item in value.items():
                yield from times(item, name)
        elif isinstance(value, str) and key.endswith("_at"):
            yield value

    found = [
        moment
        for path in sorted(SAMPLES.glob("*.json"))
        for moment in times(json.loads(path.read_text(encoding="utf-8")))
    ]

    assert found, "expected at least one *_at field in the samples"
    assert all(TIME.match(moment) for moment in found), found


def test_no_sample_contains_a_real_token() -> None:
    for path in sorted(SAMPLES.glob("*.json")):
        assert "eyJ" not in path.read_text(encoding="utf-8"), path.name
