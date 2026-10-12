"""Lister mode: creating, editing, publishing, pausing and filling a listing."""

from datetime import timedelta
from urllib.parse import urlsplit

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import Listing, ListingPhoto
from app.services.geo import distance_m
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_me import COMPLETE_PROFILE

JPEG = b"\xff\xd8\xff\xe0" + b"listing-photo" * 40

# The Ave, near UW. Made up, but a real-looking point.
LAT, LNG = 47.6588, -122.3130


def upload_listing_photos(client: TestClient, who: dict, count: int = 4) -> list[str]:
    keys = []
    for _ in range(count):
        link = client.post(
            "/v1/uploads/presign",
            headers=bearer(who),
            json={"purpose": "listing_photo", "content_type": "image/jpeg"},
        ).json()
        parts = urlsplit(link["upload_url"])
        response = client.put(f"{parts.path}?{parts.query}", content=JPEG, headers=link["headers"])
        assert response.status_code == 204, response.text
        keys.append(link["key"])
    return keys


def complete_fields(clock: Clock, photo_keys: list[str]) -> dict:
    start = clock.now.date() + timedelta(days=10)
    return {
        "address": "4500 University Way NE, Apt 3, Seattle, WA 98105",
        "latitude": LAT,
        "longitude": LNG,
        "rent_cents": 120_000,
        "deposit_cents": 50_000,
        "utilities_included": True,
        "start_date": start.isoformat(),
        "end_date": (start + timedelta(days=84)).isoformat(),
        "space_type": "private_room",
        "bedrooms": 3,
        "bathroom": "shared",
        "furnished": True,
        "laundry": True,
        "parking": False,
        "housemates_staying": 2,
        "housemates_note": "Two grad students, quiet, both cook.",
        "pets_allowed": False,
        "smoking_allowed": False,
        "gender_preference": "any",
        "same_school_only": False,
        "min_stay_days": 60,
        "landlord_consent": True,
        "photo_keys": photo_keys,
    }


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "aditi@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer) -> dict:
    return sign_in(client, mailer, "sam@northeastern.edu")


@pytest.fixture
def fields(client: TestClient, lister: dict, clock: Clock) -> dict:
    return complete_fields(clock, upload_listing_photos(client, lister))


def create(client: TestClient, who: dict, body: dict) -> dict:
    response = client.post("/v1/listings", headers=bearer(who), json=body)
    assert response.status_code == 201, response.text
    return response.json()


def set_status(client: TestClient, who: dict, listing_id: str, status: str):
    return client.post(
        f"/v1/listings/{listing_id}/status", headers=bearer(who), json={"status": status}
    )


@pytest.fixture
def published(client: TestClient, lister: dict, fields: dict) -> dict:
    listing = create(client, lister, fields)
    response = set_status(client, lister, listing["id"], "active")
    assert response.status_code == 200, response.text
    return response.json()


# --- Creating and publishing --------------------------------------------------


def test_a_listing_starts_as_an_empty_draft(client: TestClient, lister: dict) -> None:
    listing = create(client, lister, {})

    assert listing["status"] == "draft"
    assert listing["is_owner"] is True
    assert listing["photos"] == []
    assert listing["rent_cents"] is None
    assert listing["deposit_cents"] == 0
    assert listing["gender_preference"] == "any"
    assert listing["min_stay_days"] == 0
    assert listing["landlord_consent"] is None
    assert listing["published_at"] is None
    assert listing["lister"] == {
        "first_name": "Aditi",
        "photo_url": None,
        "school_name": "University of Washington",
        "verified": True,
    }


def test_a_complete_listing_can_be_published(
    client: TestClient, lister: dict, fields: dict, clock: Clock
) -> None:
    draft = create(client, lister, fields)

    response = set_status(client, lister, draft["id"], "active")

    assert response.status_code == 200
    listing = response.json()
    assert listing["status"] == "active"
    assert listing["published_at"] == clock.now.strftime("%Y-%m-%dT%H:%M:%SZ")
    assert [photo["key"] for photo in listing["photos"]] == fields["photo_keys"]
    assert all(photo["url"] for photo in listing["photos"])
    for name in ("rent_cents", "start_date", "end_date", "space_type", "housemates_note"):
        assert listing[name] == fields[name]


def test_an_empty_draft_lists_everything_still_needed(client: TestClient, lister: dict) -> None:
    draft = create(client, lister, {})

    response = set_status(client, lister, draft["id"], "active")

    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "listing_incomplete"
    assert {item["field"] for item in body["fields"]} == {
        "photo_keys",
        "address",
        "latitude",
        "rent_cents",
        "start_date",
        "end_date",
        "space_type",
        "bedrooms",
        "bathroom",
        "housemates_staying",
        "pets_allowed",
        "smoking_allowed",
        "landlord_consent",
    }
    assert all(item["message"] for item in body["fields"])
    assert (
        client.get(f"/v1/listings/{draft['id']}", headers=bearer(lister)).json()["status"]
        == "draft"
    )


@pytest.mark.parametrize(
    ("change", "field", "message"),
    [
        ({"photo_keys": "three"}, "photo_keys", "Add at least 4 photos."),
        ({"landlord_consent": None}, "landlord_consent", "landlord"),
        ({"rent_cents": None}, "rent_cents", "rent"),
        ({"pets_allowed": None}, "pets_allowed", "pets"),
    ],
)
def test_each_publishing_rule_names_its_field(
    client: TestClient, lister: dict, fields: dict, change: dict, field: str, message: str
) -> None:
    body = dict(fields)
    if change.get("photo_keys") == "three":
        body["photo_keys"] = fields["photo_keys"][:3]
    else:
        body.update(change)
    draft = create(client, lister, body)

    response = set_status(client, lister, draft["id"], "active")

    assert response.status_code == 422
    problems = response.json()["fields"]
    assert [item["field"] for item in problems] == [field]
    assert message.lower() in problems[0]["message"].lower()


def test_landlord_consent_no_is_an_answer_and_shows_on_the_listing(
    client: TestClient, lister: dict, renter: dict, fields: dict
) -> None:
    draft = create(client, lister, {**fields, "landlord_consent": False})

    published = set_status(client, lister, draft["id"], "active").json()
    seen = client.get(f"/v1/listings/{draft['id']}", headers=bearer(renter)).json()

    assert published["status"] == "active"
    assert seen["landlord_consent"] is False


def test_the_end_date_must_be_after_the_start_date(
    client: TestClient, lister: dict, fields: dict
) -> None:
    response = client.post(
        "/v1/listings",
        headers=bearer(lister),
        json={**fields, "end_date": fields["start_date"]},
    )

    assert response.status_code == 422
    assert response.json()["fields"] == [
        {"field": "end_date", "message": "The end date must be after the start date."}
    ]


def test_a_listing_whose_dates_have_passed_cannot_be_published(
    client: TestClient, lister: dict, fields: dict, clock: Clock, mailer: RecordingMailer
) -> None:
    draft = create(client, lister, fields)
    clock.advance(days=200)
    lister = sign_in(client, mailer, "aditi@uw.edu")  # the old tokens have expired

    response = set_status(client, lister, draft["id"], "active")

    assert response.status_code == 422
    assert response.json()["fields"] == [
        {"field": "end_date", "message": "The move-out date has passed."}
    ]


@pytest.mark.parametrize("rent", [0, -100])
def test_rent_must_be_above_zero(client: TestClient, lister: dict, rent: int) -> None:
    response = client.post("/v1/listings", headers=bearer(lister), json={"rent_cents": rent})

    assert response.status_code == 422
    assert response.json()["fields"][0]["field"] == "rent_cents"


def test_a_minimum_stay_longer_than_the_dates_is_refused(
    client: TestClient, lister: dict, fields: dict
) -> None:
    response = client.post(
        "/v1/listings", headers=bearer(lister), json={**fields, "min_stay_days": 90}
    )

    assert response.status_code == 422
    assert response.json()["fields"][0]["field"] == "min_stay_days"


# --- Gender preference: only for a shared home ----------------------------------


@pytest.mark.parametrize("preference", ["women", "men"])
def test_a_gender_preference_is_refused_for_a_whole_unit(
    client: TestClient, lister: dict, preference: str
) -> None:
    response = client.post(
        "/v1/listings",
        headers=bearer(lister),
        json={"space_type": "entire_unit", "gender_preference": preference},
    )

    assert response.status_code == 422
    assert response.json()["fields"][0]["field"] == "gender_preference"


@pytest.mark.parametrize("space", ["private_room", "shared_room"])
def test_a_gender_preference_is_allowed_in_a_shared_home(
    client: TestClient, lister: dict, space: str
) -> None:
    listing = create(client, lister, {"space_type": space, "gender_preference": "women"})

    assert listing["gender_preference"] == "women"


def test_switching_to_a_whole_unit_with_a_preference_set_is_refused(
    client: TestClient, lister: dict
) -> None:
    listing = create(client, lister, {"space_type": "shared_room", "gender_preference": "men"})

    response = client.patch(
        f"/v1/listings/{listing['id']}",
        headers=bearer(lister),
        json={"space_type": "entire_unit"},
    )
    allowed = client.patch(
        f"/v1/listings/{listing['id']}",
        headers=bearer(lister),
        json={"space_type": "entire_unit", "gender_preference": "any"},
    )

    assert response.status_code == 422
    assert allowed.status_code == 200


# --- Privacy: the exact address -----------------------------------------------


def test_a_second_account_cannot_read_the_exact_address(
    client: TestClient, published: dict, renter: dict
) -> None:
    response = client.get(f"/v1/listings/{published['id']}", headers=bearer(renter))

    assert response.status_code == 200
    seen = response.json()
    assert seen["is_owner"] is False
    assert seen["address"] is None
    assert seen["latitude"] is None
    assert seen["longitude"] is None
    assert "University Way" not in response.text
    assert str(LAT) not in response.text
    assert seen["public_latitude"] is not None


def test_the_owner_sees_the_exact_address(
    client: TestClient, published: dict, lister: dict
) -> None:
    seen = client.get(f"/v1/listings/{published['id']}", headers=bearer(lister)).json()

    assert seen["address"].startswith("4500 University Way")
    assert (seen["latitude"], seen["longitude"]) == (LAT, LNG)


def test_the_public_point_is_120_to_180_meters_away(published: dict) -> None:
    moved = distance_m(LAT, LNG, published["public_latitude"], published["public_longitude"])

    assert 119 <= moved <= 181


def test_the_public_point_never_changes_unless_the_address_does(
    client: TestClient, lister: dict, published: dict
) -> None:
    url = f"/v1/listings/{published['id']}"
    first = (published["public_latitude"], published["public_longitude"])

    client.patch(url, headers=bearer(lister), json={"rent_cents": 110_000})
    again = client.get(url, headers=bearer(lister)).json()
    assert (again["public_latitude"], again["public_longitude"]) == first

    moved = client.patch(
        url, headers=bearer(lister), json={"latitude": 47.6205, "longitude": -122.3493}
    ).json()
    assert (moved["public_latitude"], moved["public_longitude"]) != first
    assert (
        119
        <= distance_m(47.6205, -122.3493, moved["public_latitude"], moved["public_longitude"])
        <= 181
    )


def test_two_listings_at_the_same_address_get_different_public_points(
    client: TestClient, lister: dict
) -> None:
    first = create(client, lister, {"latitude": LAT, "longitude": LNG})
    second = create(client, lister, {"latitude": LAT, "longitude": LNG})

    assert first["public_latitude"] != second["public_latitude"]


@pytest.mark.parametrize(
    "coordinates", [{"latitude": 91, "longitude": 0}, {"latitude": 0, "longitude": -181}]
)
def test_impossible_coordinates_are_refused(
    client: TestClient, lister: dict, coordinates: dict
) -> None:
    response = client.post("/v1/listings", headers=bearer(lister), json=coordinates)

    assert response.status_code == 422


def test_other_students_see_only_active_listings(
    client: TestClient, lister: dict, renter: dict, fields: dict
) -> None:
    draft = create(client, lister, fields)
    url = f"/v1/listings/{draft['id']}"

    assert client.get(url, headers=bearer(renter)).status_code == 404
    set_status(client, lister, draft["id"], "active")
    assert client.get(url, headers=bearer(renter)).status_code == 200
    set_status(client, lister, draft["id"], "paused")
    assert client.get(url, headers=bearer(renter)).status_code == 404
    set_status(client, lister, draft["id"], "filled")
    assert client.get(url, headers=bearer(renter)).status_code == 404
    # The owner always can.
    assert client.get(url, headers=bearer(lister)).status_code == 200


def test_nobody_else_can_change_a_listing(
    client: TestClient, published: dict, renter: dict
) -> None:
    url = f"/v1/listings/{published['id']}"

    edit = client.patch(url, headers=bearer(renter), json={"rent_cents": 1})
    pause = set_status(client, renter, published["id"], "paused")

    assert edit.status_code == 404
    assert pause.status_code == 404
    assert edit.json()["code"] == "listing_not_found"


def test_an_unknown_listing_is_not_found(client: TestClient, lister: dict) -> None:
    response = client.get(
        "/v1/listings/00000000-0000-4000-8000-000000000000", headers=bearer(lister)
    )

    assert response.status_code == 404


# --- Editing, pausing and filling ---------------------------------------------


def test_a_published_listing_can_be_edited_but_must_stay_complete(
    client: TestClient, lister: dict, published: dict
) -> None:
    url = f"/v1/listings/{published['id']}"

    edited = client.patch(url, headers=bearer(lister), json={"rent_cents": 115_000})
    broken = client.patch(
        url, headers=bearer(lister), json={"photo_keys": published_keys(published)[:3]}
    )

    assert edited.status_code == 200
    assert edited.json()["rent_cents"] == 115_000
    assert broken.status_code == 422
    assert broken.json()["fields"][0]["field"] == "photo_keys"
    assert len(client.get(url, headers=bearer(lister)).json()["photos"]) == 4


def published_keys(listing: dict) -> list[str]:
    return [photo["key"] for photo in listing["photos"]]


def test_pause_and_republish(client: TestClient, lister: dict, published: dict) -> None:
    paused = set_status(client, lister, published["id"], "paused")
    again = set_status(client, lister, published["id"], "active")

    assert paused.json()["status"] == "paused"
    assert again.json()["status"] == "active"
    assert again.json()["published_at"] == published["published_at"]


def test_filled_is_final(client: TestClient, lister: dict, published: dict) -> None:
    filled = set_status(client, lister, published["id"], "filled")

    reopen = set_status(client, lister, published["id"], "active")
    edit = client.patch(
        f"/v1/listings/{published['id']}", headers=bearer(lister), json={"rent_cents": 1}
    )

    assert filled.json()["status"] == "filled"
    assert reopen.status_code == 409
    assert edit.status_code == 409
    assert edit.json()["code"] == "listing_filled"


def test_a_draft_cannot_be_paused_or_filled(client: TestClient, lister: dict) -> None:
    draft = create(client, lister, {})

    for status in ("paused", "filled"):
        response = set_status(client, lister, draft["id"], status)
        assert response.status_code == 409
        assert response.json()["code"] == "invalid_status_change"


def test_setting_the_same_status_again_changes_nothing(
    client: TestClient, lister: dict, published: dict
) -> None:
    response = set_status(client, lister, published["id"], "active")

    assert response.status_code == 200
    assert response.json()["published_at"] == published["published_at"]


def test_an_unknown_status_is_refused(client: TestClient, lister: dict, published: dict) -> None:
    for status in ("draft", "expired", "deleted"):
        response = set_status(client, lister, published["id"], status)
        assert response.status_code == 422


def test_fields_that_always_have_a_value_cannot_be_cleared(
    client: TestClient, lister: dict
) -> None:
    listing = create(client, lister, {})

    response = client.patch(
        f"/v1/listings/{listing['id']}",
        headers=bearer(lister),
        json={"deposit_cents": None, "gender_preference": None},
    )

    assert response.status_code == 422
    assert {item["field"] for item in response.json()["fields"]} == {
        "deposit_cents",
        "gender_preference",
    }


def test_optional_answers_can_be_cleared(client: TestClient, lister: dict, fields: dict) -> None:
    listing = create(client, lister, fields)

    cleared = client.patch(
        f"/v1/listings/{listing['id']}",
        headers=bearer(lister),
        json={"housemates_note": None, "rent_cents": None, "latitude": None, "longitude": None},
    ).json()

    assert cleared["housemates_note"] is None
    assert cleared["rent_cents"] is None
    assert cleared["public_latitude"] is None


def test_unknown_fields_are_refused(client: TestClient, lister: dict) -> None:
    for body in ({"owner_id": "x"}, {"status": "active"}, {"quiet_hours": "10pm"}):
        response = client.post("/v1/listings", headers=bearer(lister), json=body)
        assert response.status_code == 422, body


# --- Photos ---------------------------------------------------------------------


def test_photos_keep_their_order_and_can_be_reordered(
    client: TestClient, lister: dict, fields: dict
) -> None:
    listing = create(client, lister, fields)
    reordered = list(reversed(fields["photo_keys"]))

    response = client.patch(
        f"/v1/listings/{listing['id']}", headers=bearer(lister), json={"photo_keys": reordered}
    )

    assert published_keys(response.json()) == reordered


def test_a_removed_photo_is_deleted_from_storage(
    client: TestClient, lister: dict, fields: dict
) -> None:
    listing = create(client, lister, fields)
    removed = fields["photo_keys"][0]
    before = client.get(f"/files/{removed}")

    client.patch(
        f"/v1/listings/{listing['id']}",
        headers=bearer(lister),
        json={"photo_keys": fields["photo_keys"][1:]},
    )

    assert before.status_code == 200
    assert client.get(f"/files/{removed}").status_code == 404


def test_only_the_listers_own_listing_photos_can_be_used(
    client: TestClient, lister: dict, renter: dict
) -> None:
    someone_elses = upload_listing_photos(client, renter, count=1)[0]
    profile_photo = client.post(
        "/v1/uploads/presign",
        headers=bearer(lister),
        json={"purpose": "profile_photo", "content_type": "image/jpeg"},
    ).json()["key"]
    mine = upload_listing_photos(client, lister, count=1)[0]

    for keys in ([someone_elses], [profile_photo], ["listings/x/y.jpg"], [mine, mine]):
        response = client.post("/v1/listings", headers=bearer(lister), json={"photo_keys": keys})
        assert response.status_code == 422, keys
        assert response.json()["fields"][0]["field"] == "photo_keys"


def test_a_photo_cannot_be_on_two_listings(client: TestClient, lister: dict) -> None:
    key = upload_listing_photos(client, lister, count=1)[0]
    create(client, lister, {"photo_keys": [key]})

    response = client.post("/v1/listings", headers=bearer(lister), json={"photo_keys": [key]})

    assert response.status_code == 422


def test_at_most_twelve_photos(client: TestClient, lister: dict) -> None:
    keys = upload_listing_photos(client, lister, count=13)

    response = client.post("/v1/listings", headers=bearer(lister), json={"photo_keys": keys})

    assert response.status_code == 422


# --- My listings ----------------------------------------------------------------


def test_my_listings_shows_only_mine_newest_first_in_every_status(
    client: TestClient, lister: dict, renter: dict, published: dict, clock: Clock
) -> None:
    clock.advance(seconds=1)
    draft = create(client, lister, {})
    create(client, renter, {})

    page = client.get("/v1/me/listings", headers=bearer(lister)).json()

    assert [item["id"] for item in page["items"]] == [draft["id"], published["id"]]
    assert [item["status"] for item in page["items"]] == ["draft", "active"]
    assert page["next_cursor"] is None
    assert all(item["address"] or item["status"] == "draft" for item in page["items"])


def test_my_listings_pages_with_a_cursor(client: TestClient, lister: dict) -> None:
    created = [create(client, lister, {})["id"] for _ in range(5)]

    seen: list[str] = []
    cursor = None
    while True:
        params = {"limit": 2, **({"cursor": cursor} if cursor else {})}
        page = client.get("/v1/me/listings", headers=bearer(lister), params=params).json()
        seen += [item["id"] for item in page["items"]]
        cursor = page["next_cursor"]
        if cursor is None:
            break

    assert sorted(seen) == sorted(created)
    assert len(seen) == 5


def test_a_broken_cursor_is_refused(client: TestClient, lister: dict) -> None:
    response = client.get(
        "/v1/me/listings", headers=bearer(lister), params={"cursor": "not-a-cursor"}
    )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_cursor"


# --- Staying around -----------------------------------------------------------


def test_a_listing_survives_a_server_restart(
    published: dict, lister: dict, settings, clock: Clock
) -> None:
    from app.deps import get_now
    from app.main import create_app

    restarted = create_app(settings)
    restarted.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(restarted) as client:
        seen = client.get(f"/v1/listings/{published['id']}", headers=bearer(lister)).json()

    assert seen["status"] == "active"
    assert published_keys(seen) == published_keys(published)


def test_deleting_the_account_removes_its_listings_and_their_photos(
    client: TestClient, lister: dict, published: dict, db: Session
) -> None:
    keys = published_keys(published)

    assert client.delete("/v1/me", headers=bearer(lister)).status_code == 204

    assert db.scalar(select(func.count()).select_from(Listing)) == 0
    assert db.scalar(select(func.count()).select_from(ListingPhoto)) == 0
    assert all(client.get(f"/files/{key}").status_code == 404 for key in keys)


# --- Dependency unavailable -----------------------------------------------------


def test_listings_say_try_again_when_the_database_is_down(app, lister: dict, settings) -> None:
    from app.db import make_engine
    from tests.conftest import UNREACHABLE_DATABASE_URL

    app.state.engine = make_engine(
        settings.model_copy(
            update={"database_url": UNREACHABLE_DATABASE_URL, "db_connect_timeout_s": 1}
        )
    )
    with TestClient(app) as client:
        response = client.post("/v1/listings", headers=bearer(lister), json={})

    assert response.status_code == 503
    assert response.json()["code"] == "service_unavailable"


def test_a_draft_can_be_saved_without_photos_when_uploads_are_off(
    settings, clock: Clock, mailer: RecordingMailer
) -> None:
    from app.deps import get_now
    from app.main import create_app

    app = create_app(settings.model_copy(update={"storage_backend": "none"}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        who = sign_in(client, mailer, "aditi@uw.edu")
        response = client.post("/v1/listings", headers=bearer(who), json={"rent_cents": 90_000})

    assert response.status_code == 201
