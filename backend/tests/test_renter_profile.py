"""Renter mode: saving what a renter needs, and keeping their pin private."""

import json
from datetime import date

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import RenterProfile, User
from tests.conftest import REPO_ROOT, RecordingMailer, bearer, sign_in

PATH = "/v1/me/renter-profile"

# A pin with digits nobody else would produce, so a leak is easy to spot.
PIN = {"latitude": 47.6553117, "longitude": -122.3035993, "radius_m": 3217}

FULL_PROFILE = {
    "start_date": "2027-06-15",
    "end_date": "2027-09-01",
    "flexibility_days": 7,
    "max_rent_cents": 110_000,
    "preferences": [
        {"field": "space_type", "value": ["private_room", "entire_unit"], "importance": "must"},
        {"field": "private_bathroom", "value": True, "importance": "nice"},
        {"field": "furnished", "value": True, "importance": "must"},
        {"field": "laundry", "value": True, "importance": "nice"},
        {"field": "parking", "value": True, "importance": "off"},
        {"field": "pet_free", "value": True, "importance": "off"},
        {"field": "smoke_free", "value": True, "importance": "must"},
        {"field": "housemate_count", "value": 2, "importance": "nice"},
        {"field": "housemate_gender", "value": "women", "importance": "must"},
    ],
    "pin": PIN,
    "notify_new_listings": True,
}


def save(client: TestClient, who: dict, body: dict):
    return client.put(PATH, headers=bearer(who), json=body)


def test_a_new_renter_has_an_empty_profile(client: TestClient, aditi: dict) -> None:
    body = client.get(PATH, headers=bearer(aditi)).json()

    assert body == {
        "start_date": None,
        "end_date": None,
        "flexibility_days": 0,
        "max_rent_cents": None,
        "preferences": [],
        "pin": None,
        "notify_new_listings": False,
        "complete": False,
        "updated_at": None,
    }


def test_preferences_save_and_reload_exactly(client: TestClient, aditi: dict) -> None:
    saved = save(client, aditi, FULL_PROFILE)
    assert saved.status_code == 200, saved.text

    reloaded = client.get(PATH, headers=bearer(aditi)).json()

    assert reloaded == saved.json()
    sent = {key: value for key, value in reloaded.items() if key not in ("complete", "updated_at")}
    assert sent == FULL_PROFILE
    assert reloaded["complete"] is True
    assert reloaded["updated_at"].endswith("Z")


def test_types_survive_the_round_trip(client: TestClient, aditi: dict) -> None:
    """true must not come back as 1, nor 2 as true."""
    save(client, aditi, FULL_PROFILE)

    values = {
        item["field"]: item["value"]
        for item in client.get(PATH, headers=bearer(aditi)).json()["preferences"]
    }

    assert values["furnished"] is True
    assert values["housemate_count"] == 2 and values["housemate_count"] is not True


def test_saving_again_replaces_the_whole_profile(client: TestClient, aditi: dict) -> None:
    save(client, aditi, FULL_PROFILE)

    body = save(client, aditi, {"max_rent_cents": 90_000}).json()

    assert body["max_rent_cents"] == 90_000
    assert body["preferences"] == []
    assert body["pin"] is None
    assert body["start_date"] is None
    assert body["complete"] is False


def test_a_partial_profile_can_be_saved_and_is_not_complete(
    client: TestClient, aditi: dict
) -> None:
    body = save(client, aditi, {"start_date": "2027-06-15", "end_date": "2027-09-01"}).json()

    assert body["complete"] is False
    assert body["start_date"] == "2027-06-15"


@pytest.mark.parametrize("missing", ["start_date", "end_date", "max_rent_cents", "pin"])
def test_complete_needs_dates_budget_and_pin(client: TestClient, aditi: dict, missing: str) -> None:
    body = {key: value for key, value in FULL_PROFILE.items() if key != missing}

    assert save(client, aditi, body).json()["complete"] is False


def test_one_profile_per_user(client: TestClient, aditi: dict, db: Session) -> None:
    save(client, aditi, FULL_PROFILE)
    save(client, aditi, FULL_PROFILE)

    assert len(db.scalars(select(RenterProfile)).all()) == 1


# --- Validation ---------------------------------------------------------------


def problems(response) -> dict[str, str]:
    assert response.status_code == 422, response.text
    body = response.json()
    assert body["code"] == "validation_error"
    return {item["field"]: item["message"] for item in body["fields"]}


def test_end_date_must_be_after_start_date(client: TestClient, aditi: dict) -> None:
    found = problems(save(client, aditi, {"start_date": "2027-09-01", "end_date": "2027-09-01"}))

    assert "end_date" in found


@pytest.mark.parametrize(
    ("preference", "field"),
    [
        ({"field": "furnished", "value": False, "importance": "must"}, "preferences.0.value"),
        ({"field": "furnished", "value": 1, "importance": "must"}, "preferences.0.value"),
        ({"field": "space_type", "value": [], "importance": "must"}, "preferences.0.value"),
        ({"field": "space_type", "value": ["castle"], "importance": "must"}, "preferences.0.value"),
        (
            {
                "field": "space_type",
                "value": ["private_room", "private_room"],
                "importance": "nice",
            },
            "preferences.0.value",
        ),
        ({"field": "housemate_count", "value": 11, "importance": "must"}, "preferences.0.value"),
        ({"field": "housemate_count", "value": True, "importance": "must"}, "preferences.0.value"),
        (
            {"field": "housemate_gender", "value": "any", "importance": "must"},
            "preferences.0.value",
        ),
        (
            {"field": "housemate_gender", "value": "nonbinary", "importance": "nice"},
            "preferences.0.value",
        ),
    ],
)
def test_each_preference_checks_its_value(
    client: TestClient, aditi: dict, preference: dict, field: str
) -> None:
    found = problems(save(client, aditi, {"preferences": [preference]}))

    assert list(found) == [field]
    assert found[field]


def test_unknown_preferences_and_importances_are_refused(client: TestClient, aditi: dict) -> None:
    response = save(
        client,
        aditi,
        {"preferences": [{"field": "pool", "value": True, "importance": "must"}]},
    )
    assert response.status_code == 422

    response = save(
        client,
        aditi,
        {"preferences": [{"field": "parking", "value": True, "importance": "always"}]},
    )
    assert response.status_code == 422


def test_a_preference_cannot_be_listed_twice(client: TestClient, aditi: dict) -> None:
    item = {"field": "laundry", "value": True, "importance": "nice"}

    found = problems(save(client, aditi, {"preferences": [item, item]}))

    assert list(found) == ["preferences.1.field"]


@pytest.mark.parametrize(
    "pin",
    [
        {**PIN, "radius_m": 100},
        {**PIN, "radius_m": 80_000},
        {**PIN, "latitude": 91},
        {**PIN, "longitude": -181},
        {"latitude": 47.6, "longitude": -122.3},
    ],
)
def test_the_pin_must_be_a_real_place_with_a_sensible_radius(
    client: TestClient, aditi: dict, pin: dict
) -> None:
    assert save(client, aditi, {"pin": pin}).status_code == 422


def test_nothing_is_saved_when_validation_fails(client: TestClient, aditi: dict) -> None:
    save(client, aditi, FULL_PROFILE)

    save(client, aditi, {**FULL_PROFILE, "end_date": "2027-01-01"})

    assert client.get(PATH, headers=bearer(aditi)).json()["end_date"] == "2027-09-01"


def test_signing_in_is_required(client: TestClient) -> None:
    assert client.get(PATH).status_code == 401
    assert client.put(PATH, json=FULL_PROFILE).status_code == 401


# --- Privacy --------------------------------------------------------------------


def _leaks(text: str) -> list[str]:
    # Coordinates with a dot can't appear by chance inside an id or a token.
    needles = ["47.6553117", "-122.3035993", "pin_latitude", "pin_longitude"]
    return [needle for needle in needles if needle in text]


def test_no_endpoint_returns_one_users_pin_to_another_user(
    client: TestClient, mailer: RecordingMailer
) -> None:
    """Calls every GET endpoint in the contract as a second user, with the first
    user's ids filled in, and looks for the first user's pin in every answer.

    New GET endpoints are covered as soon as they are added to endpoints.json.
    """
    from tests.test_me import COMPLETE_PROFILE

    owner = sign_in(client, mailer, "aditi@uw.edu")
    client.patch("/v1/me", headers=bearer(owner), json=COMPLETE_PROFILE)
    assert save(client, owner, FULL_PROFILE).status_code == 200
    listing = client.post("/v1/listings", headers=bearer(owner), json={"rent_cents": 90_000}).json()

    other = sign_in(client, mailer, "sam@northeastern.edu")
    client.patch("/v1/me", headers=bearer(other), json=COMPLETE_PROFILE)
    save(
        client,
        other,
        {**FULL_PROFILE, "pin": {"latitude": 42.34, "longitude": -71.09, "radius_m": 5000}},
    )

    ids = {"listing_id": listing["id"], "user_id": owner["user"]["id"], "key": "x"}
    entries = json.loads((REPO_ROOT / "docs/contract/endpoints.json").read_text())["endpoints"]
    checked = 0
    for entry in entries:
        if entry["method"] != "GET" or entry.get("own_storage_only"):
            continue
        path = entry["path"]
        for name, value in ids.items():
            path = path.replace("{" + name + "}", value)
        assert "{" not in path, f"no test value for a placeholder in {entry['path']}"
        response = client.get(path, headers=bearer(other))
        found = _leaks(response.text)
        assert not found, f"{entry['path']} returned {found}"
        checked += 1
    assert checked >= 4


def test_only_the_owner_reads_their_renter_profile(
    client: TestClient, mailer: RecordingMailer
) -> None:
    owner = sign_in(client, mailer, "aditi@uw.edu")
    save(client, owner, FULL_PROFILE)
    other = sign_in(client, mailer, "sam@northeastern.edu")

    body = client.get(PATH, headers=bearer(other)).json()

    assert body["pin"] is None
    assert _leaks(json.dumps(body)) == []


def test_deleting_the_account_deletes_the_renter_profile(
    client: TestClient, aditi: dict, db: Session
) -> None:
    save(client, aditi, FULL_PROFILE)

    assert client.delete("/v1/me", headers=bearer(aditi)).status_code == 204

    assert db.scalars(select(RenterProfile)).all() == []
    assert db.scalars(select(User)).all() == []


def test_dates_are_plain_calendar_days(client: TestClient, aditi: dict, db: Session) -> None:
    save(client, aditi, FULL_PROFILE)

    profile = db.scalars(select(RenterProfile)).one()

    assert profile.start_date == date(2027, 6, 15)
