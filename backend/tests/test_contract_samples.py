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


def test_listing_samples(client: TestClient, aditi: dict, mailer: RecordingMailer, clock) -> None:
    from tests.test_listings import complete_fields, upload_listing_photos

    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)
    fields = complete_fields(clock, upload_listing_photos(client, aditi))
    draft = client.post("/v1/listings", headers=bearer(aditi), json={"rent_cents": 90_000})
    check("listing_draft", draft.json())
    check(
        "error_listing_incomplete",
        client.post(
            f"/v1/listings/{draft.json()['id']}/status",
            headers=bearer(aditi),
            json={"status": "active"},
        ).json(),
    )

    listing = client.post("/v1/listings", headers=bearer(aditi), json=fields).json()
    published = client.post(
        f"/v1/listings/{listing['id']}/status", headers=bearer(aditi), json={"status": "active"}
    ).json()
    # Public points are random; pin them so the sample stays stable.
    for body in (published,):
        body["public_latitude"], body["public_longitude"] = 47.6601, -122.3119
    check("listing_owner", published)

    renter = sign_in(client, mailer, "sam@northeastern.edu")
    seen = client.get(f"/v1/listings/{listing['id']}", headers=bearer(renter)).json()
    seen["public_latitude"], seen["public_longitude"] = 47.6601, -122.3119
    check("listing_public", seen)

    page = client.get("/v1/me/listings", headers=bearer(aditi), params={"limit": 1}).json()
    page["items"][0]["public_latitude"] = page["items"][0]["public_longitude"] = None
    page["next_cursor"] = "sample-cursor" if page["next_cursor"] else None
    check("my_listings", page)


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


def test_renter_profile_samples(client: TestClient, aditi: dict) -> None:
    from tests.test_renter_profile import FULL_PROFILE

    check("renter_profile_empty", client.get("/v1/me/renter-profile", headers=bearer(aditi)).json())
    check(
        "renter_profile",
        client.put("/v1/me/renter-profile", headers=bearer(aditi), json=FULL_PROFILE).json(),
    )


def test_deck_samples(client: TestClient, mailer: RecordingMailer, clock, db) -> None:
    from tests.test_deck import make_lister, put_listing, search

    renter = sign_in(client, mailer, "renter@uw.edu")
    client.patch("/v1/me", headers=bearer(renter), json={**COMPLETE_PROFILE, "gender": "woman"})
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json=search(
            clock,
            preferences=[
                {"field": "furnished", "value": True, "importance": "nice"},
                {"field": "laundry", "value": True, "importance": "nice"},
                {"field": "parking", "value": True, "importance": "must"},
            ],
        ),
    )
    lister = make_lister(db)
    lister.email = "lister@uw.edu"
    put_listing(db, clock, lister, parking=True)
    put_listing(db, clock, lister, parking=False)

    page = client.get("/v1/deck/listings", headers=bearer(renter)).json()
    check("deck_listings", page)
    check("deck_diagnostics", client.get("/v1/deck/diagnostics", headers=bearer(renter)).json())
    check(
        "error_profile_incomplete",
        client.get("/v1/deck/listings", headers=bearer(sign_in(client, mailer, "x@uw.edu"))).json(),
    )


def test_swipe_samples(client: TestClient, mailer: RecordingMailer, clock, db) -> None:
    import uuid as uuid_module

    from app.models import User
    from tests.test_deck import make_searching_renter, put_listing

    renter = make_searching_renter(client, mailer, clock)
    lister = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(lister), json=COMPLETE_PROFILE)
    listing = put_listing(db, clock, db.get(User, uuid_module.UUID(lister["user"]["id"])))
    swipe_id = "22222222-3333-4444-8555-666666666666"

    liked = client.post(
        "/v1/swipes",
        headers=bearer(renter),
        json={"listing_id": str(listing.id), "action": "like", "swipe_id": swipe_id},
    ).json()
    check("swipe_result", liked)
    check(
        "interested_renters",
        client.get(f"/v1/listings/{listing.id}/deck/renters", headers=bearer(lister)).json(),
    )
    matched = client.post(
        "/v1/swipes",
        headers=bearer(lister),
        json={"listing_id": str(listing.id), "renter_id": renter["user"]["id"], "action": "like"},
    ).json()
    check("swipe_result_match", matched)
    check("matches", client.get("/v1/matches", headers=bearer(renter)).json())
    check(
        "error_already_matched",
        client.post("/v1/swipes/undo", headers=bearer(renter), json={"swipe_id": swipe_id}).json(),
    )

    other = put_listing(db, clock, db.get(User, uuid_module.UUID(lister["user"]["id"])))
    client.post(f"/v1/saved/{other.id}", headers=bearer(renter))
    check("saved", client.get("/v1/saved", headers=bearer(renter)).json())
    passed = client.post(
        "/v1/swipes",
        headers=bearer(renter),
        json={"listing_id": str(other.id), "action": "pass"},
    ).json()
    check(
        "undo",
        client.post(
            "/v1/swipes/undo", headers=bearer(renter), json={"swipe_id": passed["swipe"]["id"]}
        ).json(),
    )
