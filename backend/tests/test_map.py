"""The renter's map: which pins, what color, and who sees the exact address."""

import json
import random
import time
import uuid
from datetime import date

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import seed_fake
from app.models import User
from app.services.matching import score_band
from tests.conftest import REPO_ROOT, Clock, RecordingMailer, bearer, sign_in
from tests.test_deck import (
    KM,
    PIN,
    deck,
    ids,
    make_lister,
    make_searching_renter,
    put_listing,
    search,
)
from tests.test_deck import signed_in_as as signed_in_as_seeded
from tests.test_me import COMPLETE_PROFILE


def box(west: float, south: float, east: float, north: float) -> str:
    """A bbox parameter, in degrees around the renter's pin."""
    lat, lng = PIN["latitude"], PIN["longitude"]
    return f"{lng - west},{lat - south},{lng + east},{lat + north}"


# About 30 km on a side: bigger than the renter's 5 km circle.
WIDE = box(0.2, 0.15, 0.2, 0.15)


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


def owner(db: Session, who: dict) -> User:
    return db.get(User, uuid.UUID(who["user"]["id"]))


def pins(client: TestClient, who: dict, bbox: str = WIDE) -> list[dict]:
    response = client.get("/v1/map/listings", headers=bearer(who), params={"bbox": bbox})
    assert response.status_code == 200, response.text
    return response.json()["items"]


def by_id(items: list[dict]) -> dict[str, dict]:
    return {item["id"]: item for item in items}


def swipe(client: TestClient, who: dict, listing_id, action="like", **extra) -> dict:
    body = {
        "listing_id": str(listing_id),
        "action": action,
        **{k: str(v) for k, v in extra.items()},
    }
    response = client.post("/v1/swipes", headers=bearer(who), json=body)
    assert response.status_code == 200, response.text
    return response.json()


# --- Which pins --------------------------------------------------------------------


def test_the_map_shows_the_decks_listings_at_their_public_points(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, make_lister(db))

    [pin] = pins(client, renter)

    assert pin["id"] == str(listing.id)
    assert pin["state"] == "new"
    assert pin["exact"] is False
    assert pin["latitude"] == pytest.approx(listing.public_latitude)
    assert pin["latitude"] != pytest.approx(listing.latitude)
    assert pin["rent_cents"] == 100_000


def test_pins_outside_the_box_or_the_circle_are_left_out(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    near = put_listing(db, clock, lister, km_north=1)
    put_listing(db, clock, lister, km_north=4)  # in the circle, outside the small box
    put_listing(db, clock, lister, km_north=8)  # in the wide box, outside the circle
    small = box(0.05, 0.01, 0.05, 2 * KM)

    assert [pin["id"] for pin in pins(client, renter, small)] == [str(near.id)]
    assert len(pins(client, renter)) == 2


def test_ineligible_and_passed_listings_are_not_pins(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    put_listing(db, clock, lister, gender_preference="men")
    passed = put_listing(db, clock, lister)
    swipe(client, renter, passed.id, "pass")

    assert pins(client, renter) == []


def test_bands_follow_the_score(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    put_listing(db, clock, make_lister(db))
    put_listing(db, clock, make_lister(db), rent_cents=150_000, km_north=4.5)

    found = pins(client, renter)

    assert all(pin["band"] == score_band(pin["score"]) for pin in found)
    assert {pin["band"] for pin in found} == {"strong", "partial"}


@pytest.mark.parametrize(
    ("value", "band"),
    [
        (100, "strong"),
        (75, "strong"),
        (74, "partial"),
        (50, "partial"),
        (49, "other"),
        (0, "other"),
    ],
)
def test_score_band(value: int, band: str) -> None:
    assert score_band(value) == band


def test_liked_saved_and_matched_pins_keep_their_state(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    mine = owner(db, lister)
    liked = put_listing(db, clock, mine)
    saved = put_listing(db, clock, mine)
    matched = put_listing(db, clock, mine)
    fresh = put_listing(db, clock, mine)
    swipe(client, renter, liked.id)
    client.post(f"/v1/saved/{saved.id}", headers=bearer(renter))
    swipe(client, renter, matched.id)
    swipe(client, lister, matched.id, renter_id=renter["user"]["id"])

    found = by_id(pins(client, renter))

    assert {key: pin["state"] for key, pin in found.items()} == {
        str(liked.id): "liked",
        str(saved.id): "saved",
        str(matched.id): "matched",
        str(fresh.id): "new",
    }
    assert next(iter(found)) == str(matched.id), "matched pins come first"


# --- Map and deck agree --------------------------------------------------------------


def test_map_and_deck_show_the_same_listings_for_the_same_search(
    client: TestClient, db: Session, clock: Clock
) -> None:
    seed_fake.seed_fake_data(db, today=clock.now.date(), rng=random.Random(11))
    db.commit()
    emails = db.scalars(
        select(User.email).where(User.email.like("seed-renter-%")).order_by(User.email)
    ).all()
    checked = 0
    for email in emails[:30]:
        who = signed_in_as_seeded(client, email)
        shown = set(ids(deck(client, who, limit=50)))
        if not 0 < len(shown) < 50:
            continue  # the deck stops at 50; compare only decks that show everything
        whole_world = "-180,-90,180,90"
        new = {pin["id"] for pin in pins(client, who, whole_world) if pin["state"] == "new"}
        assert new == shown, email
        checked += 1
    assert checked >= 5


# --- Exact location --------------------------------------------------------------------


EXACT_ADDRESS = "1 Private Way"


def exact_marks(listing) -> list[str]:
    return [EXACT_ADDRESS, repr(round(listing.latitude, 6))[:9]]


def test_an_unmatched_renter_never_receives_an_exact_location(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    """Every GET endpoint, called by a renter who liked and saved the listing but
    did not match: none may carry the real address or point."""
    listing = put_listing(db, clock, owner(db, lister), latitude=47.6612345, address=EXACT_ADDRESS)
    swipe(client, renter, listing.id)
    other = put_listing(db, clock, owner(db, lister), latitude=47.6612345, address=EXACT_ADDRESS)
    client.post(f"/v1/saved/{other.id}", headers=bearer(renter))

    entries = json.loads((REPO_ROOT / "docs/contract/endpoints.json").read_text())["endpoints"]
    checked = 0
    for entry in entries:
        if entry["method"] != "GET" or entry.get("own_storage_only"):
            continue
        for target in (listing, other):
            path = entry["path"].replace("{listing_id}", str(target.id))
            response = client.get(path, headers=bearer(renter), params={"bbox": WIDE})
            for mark in (EXACT_ADDRESS, "47.6612345"):
                assert mark not in response.text, f"{entry['path']} leaked {mark}"
            checked += 1
    assert checked >= 10


def test_a_matched_renter_gets_the_exact_location(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, owner(db, lister), latitude=47.6612345, address=EXACT_ADDRESS)
    swipe(client, renter, listing.id)
    swipe(client, lister, listing.id, renter_id=renter["user"]["id"])

    pin = by_id(pins(client, renter))[str(listing.id)]
    card = client.get(f"/v1/map/listings/{listing.id}", headers=bearer(renter)).json()
    read = client.get(f"/v1/listings/{listing.id}", headers=bearer(renter)).json()
    match = client.get("/v1/matches", headers=bearer(renter)).json()["items"][0]

    assert pin["exact"] is True and pin["latitude"] == pytest.approx(47.6612345)
    assert card["state"] == "matched"
    for shown in (card["item"]["listing"], read, match["listing"]):
        assert shown["is_matched"] is True
        assert shown["address"] == EXACT_ADDRESS
        assert shown["latitude"] == pytest.approx(47.6612345)


def test_a_match_does_not_reveal_the_address_to_anyone_else(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock, mailer
) -> None:
    listing = put_listing(db, clock, owner(db, lister), address=EXACT_ADDRESS)
    swipe(client, renter, listing.id)
    swipe(client, lister, listing.id, renter_id=renter["user"]["id"])
    stranger = make_searching_renter_named(client, mailer, clock, "stranger@uw.edu")

    for response in (
        client.get(f"/v1/listings/{listing.id}", headers=bearer(stranger)),
        client.get("/v1/map/listings", headers=bearer(stranger), params={"bbox": WIDE}),
        client.get(f"/v1/map/listings/{listing.id}", headers=bearer(stranger)),
    ):
        assert EXACT_ADDRESS not in response.text


def make_searching_renter_named(client, mailer, clock, email: str) -> dict:
    who = sign_in(client, mailer, email)
    client.patch("/v1/me", headers=bearer(who), json={**COMPLETE_PROFILE, "gender": "woman"})
    client.put("/v1/me/renter-profile", headers=bearer(who), json=search(clock))
    return who


def test_a_matched_renter_can_still_read_a_listing_after_it_is_filled(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, owner(db, lister))
    swipe(client, renter, listing.id)
    swipe(client, lister, listing.id, renter_id=renter["user"]["id"])
    listing.status = "filled"
    db.commit()

    assert client.get(f"/v1/listings/{listing.id}", headers=bearer(renter)).status_code == 200


# --- Cards ------------------------------------------------------------------------------


def test_a_pins_card_is_the_decks_card(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, make_lister(db))
    [from_deck] = deck(client, renter)

    card = client.get(f"/v1/map/listings/{listing.id}", headers=bearer(renter)).json()

    assert card["state"] == "new"
    assert card["item"] == from_deck


def test_no_card_for_a_listing_the_map_would_not_show(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    unfit = put_listing(db, clock, lister, gender_preference="men")
    passed = put_listing(db, clock, lister)
    swipe(client, renter, passed.id, "pass")

    for listing_id in (unfit.id, passed.id, uuid.uuid4()):
        response = client.get(f"/v1/map/listings/{listing_id}", headers=bearer(renter))
        assert response.status_code == 404


# --- The box and the limits ---------------------------------------------------------------


@pytest.mark.parametrize(
    "bbox", ["", "1,2,3", "a,b,c,d", "10,0,5,1", "0,10,1,5", "-200,0,1,1", "0,-95,1,1"]
)
def test_a_bad_box_is_refused(client: TestClient, renter: dict, bbox: str) -> None:
    response = client.get("/v1/map/listings", headers=bearer(renter), params={"bbox": bbox})

    assert response.status_code == 422
    assert response.json()["code"] in ("invalid_bbox", "validation_error")


def test_the_map_needs_a_search(client: TestClient, mailer: RecordingMailer) -> None:
    who = sign_in(client, mailer, "new@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)

    response = client.get("/v1/map/listings", headers=bearer(who), params={"bbox": WIDE})

    assert response.json()["code"] == "renter_profile_incomplete"


def test_signing_in_is_required(client: TestClient) -> None:
    assert client.get("/v1/map/listings", params={"bbox": WIDE}).status_code == 401
    assert client.get(f"/v1/map/listings/{uuid.uuid4()}").status_code == 401


def test_at_most_500_pins_best_first(
    client: TestClient, renter: dict, db: Session, clock: Clock, monkeypatch
) -> None:
    from app.services import maps

    monkeypatch.setattr(maps, "MAX_PINS", 3)
    lister = make_lister(db)
    for km in (0.2, 1, 2, 3, 4):
        put_listing(db, clock, lister, km_north=km)

    response = client.get("/v1/map/listings", headers=bearer(renter), params={"bbox": WIDE}).json()

    assert len(response["items"]) == 3
    assert response["truncated"] is True
    scores = [pin["score"] for pin in response["items"]]
    assert scores == sorted(scores, reverse=True)


def test_500_pins_answer_quickly(client: TestClient, db: Session, clock: Clock) -> None:
    """A wide renter circle around a campus with 600 listings in it."""
    seed_fake.seed_fake_data(
        db, listings=1_800, renters=3, today=date(2027, 1, 4), rng=random.Random(5)
    )
    db.commit()
    email = db.scalar(select(User.email).where(User.email.like("seed-renter-0@%")))
    who = signed_in_as_seeded(client, email)
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(who),
        json={
            **search(clock),
            "max_rent_cents": 300_000,
            "pin": {
                "latitude": seed_fake.CAMPUSES[0].latitude,
                "longitude": seed_fake.CAMPUSES[0].longitude,
                "radius_m": 50_000,
            },
        },
    )
    pins(client, who, "-180,-90,180,90")  # warm up

    started = time.perf_counter()
    found = pins(client, who, "-180,-90,180,90")
    elapsed = time.perf_counter() - started

    assert len(found) > 100
    assert elapsed < 0.5, f"{elapsed:.3f}s for {len(found)} pins"
