"""The deck: what a renter is shown, in what order, and why the deck is short."""

import random
import statistics
import time
import uuid
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import seed_fake
from app.config import Settings
from app.models import Listing, ListingPhoto, RenterProfile, SchoolDomain, StoredFile, User
from app.services.deck import candidates
from app.services.matching import Renter, failures
from app.services.storage import DatabaseStore
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_me import COMPLETE_PROFILE

PIN = {"latitude": 47.6553, "longitude": -122.3035, "radius_m": 5_000}
KM = 1 / 111.32  # degrees of latitude


def search(clock: Clock, **changes) -> dict:
    start = clock.now.date() + timedelta(days=30)
    body = {
        "start_date": start.isoformat(),
        "end_date": (start + timedelta(days=90)).isoformat(),
        "flexibility_days": 0,
        "max_rent_cents": 120_000,
        "preferences": [],
        "pin": PIN,
    }
    body.update(changes)
    return body


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    """A UW student with a complete profile and a search around campus."""
    who = sign_in(client, mailer, "renter@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json={**COMPLETE_PROFILE, "gender": "woman"})
    response = client.put("/v1/me/renter-profile", headers=bearer(who), json=search(clock))
    assert response.status_code == 200, response.text
    return who


def school_id(db: Session, domain: str) -> uuid.UUID:
    return db.get(SchoolDomain, domain).school_id


def make_lister(db: Session, domain: str = "uw.edu", status: str = "active") -> User:
    user = User(
        id=uuid.uuid4(),
        email=f"lister-{uuid.uuid4().hex[:8]}@{domain}",
        school_id=school_id(db, domain),
        verified_at=func.now(),
        first_name="Lee",
        year="senior",
        program="Design",
        smokes=False,
        has_pets=False,
        status=status,
    )
    db.add(user)
    db.flush()
    return user


def put_listing(
    db: Session, clock: Clock, owner: User, km_north: float = 0.5, **changes
) -> Listing:
    """A live listing that fits the `renter` fixture's search, `km_north` of the pin."""
    start = clock.now.date() + timedelta(days=30)
    values = dict(
        id=uuid.uuid4(),
        owner_id=owner.id,
        status="active",
        address="1 Private Way",
        latitude=PIN["latitude"] + km_north * KM + 0.001,
        longitude=PIN["longitude"],
        public_latitude=PIN["latitude"] + km_north * KM,
        public_longitude=PIN["longitude"],
        rent_cents=100_000,
        deposit_cents=0,
        utilities_included=False,
        start_date=start,
        end_date=start + timedelta(days=90),
        space_type="private_room",
        bedrooms=3,
        bathroom="shared",
        furnished=True,
        laundry=True,
        parking=False,
        housemates_staying=2,
        household_gender="mixed",
        pets_allowed=True,
        smoking_allowed=False,
        gender_preference="any",
        same_school_only=False,
        min_stay_days=0,
        landlord_consent=True,
        published_at=clock.now,
    )
    values.update(changes)
    listing = Listing(**values)
    db.add(listing)
    db.commit()
    return listing


def deck(client: TestClient, who: dict, **params) -> list[dict]:
    response = client.get("/v1/deck/listings", headers=bearer(who), params=params)
    assert response.status_code == 200, response.text
    return response.json()["items"]


def ids(items: list[dict]) -> list[str]:
    return [item["listing"]["id"] for item in items]


# --- What is shown ------------------------------------------------------------


def test_a_fitting_listing_is_shown_with_its_score_and_reasons(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, make_lister(db))

    items = deck(client, renter)

    assert ids(items) == [str(listing.id)]
    item = items[0]
    assert 0 <= item["score"] <= 100
    assert item["reasons"][0] == "Fits your dates"
    assert item["reasons"][1] == "$200 under budget"
    assert 3 <= len(item["reasons"]) <= 4
    assert 450 <= item["distance_m"] <= 550


def test_the_deck_never_shows_the_exact_address(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, make_lister(db))

    shown = deck(client, renter)[0]["listing"]

    assert shown["is_owner"] is False
    assert shown["address"] is None
    assert shown["latitude"] is None and shown["longitude"] is None
    assert shown["public_latitude"] == pytest.approx(listing.public_latitude)
    assert str(listing.latitude) not in str(shown)


def test_only_live_listings_inside_the_circle_from_active_accounts(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    shown = put_listing(db, clock, lister, km_north=4.9)
    put_listing(db, clock, lister, km_north=5.2)  # just outside the circle
    put_listing(db, clock, lister, status="draft")
    put_listing(db, clock, lister, status="paused")
    put_listing(db, clock, lister, status="filled")
    put_listing(
        db,
        clock,
        lister,
        start_date=clock.now.date() - timedelta(days=60),
        end_date=clock.now.date() - timedelta(days=1),
    )
    put_listing(db, clock, make_lister(db, status="suspended"))

    assert ids(deck(client, renter)) == [str(shown.id)]


def test_a_renters_own_listings_are_never_in_their_deck(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    me = db.get(User, uuid.UUID(renter["user"]["id"]))
    put_listing(db, clock, me)

    assert deck(client, renter) == []


def test_best_fit_first_then_newest(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    far = put_listing(db, clock, lister, km_north=3)
    near_old = put_listing(
        db, clock, lister, km_north=0.2, published_at=clock.now - timedelta(days=2)
    )
    near_new = put_listing(db, clock, lister, km_north=0.2, published_at=clock.now)

    items = deck(client, renter)

    assert ids(items) == [str(near_new.id), str(near_old.id), str(far.id)]
    assert items[0]["score"] == items[1]["score"] > items[2]["score"]


def test_the_limit_caps_the_deck(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    lister = make_lister(db)
    for _ in range(5):
        put_listing(db, clock, lister)

    assert len(deck(client, renter, limit=3)) == 3


def test_an_ineligible_listing_never_appears_whatever_its_score(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    """Each listing here would score 100: right dates, under budget, at the pin."""
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json=search(
            clock, preferences=[{"field": "furnished", "value": True, "importance": "must"}]
        ),
    )
    client.patch("/v1/me", headers=bearer(renter), json={"has_pets": True})
    lister = make_lister(db)
    other_school = make_lister(db, domain="bu.edu")
    fits = put_listing(db, clock, lister, km_north=0)
    put_listing(db, clock, lister, km_north=0, furnished=False)  # fails a must-have
    put_listing(db, clock, lister, km_north=0, pets_allowed=False)  # renter has pets
    put_listing(db, clock, lister, km_north=0, gender_preference="men")  # renter is a woman
    put_listing(db, clock, other_school, km_north=0, same_school_only=True)
    put_listing(db, clock, lister, km_north=0, min_stay_days=120)

    assert ids(deck(client, renter, limit=50)) == [str(fits.id)]


def test_non_binary_renters_see_places_for_women_and_for_men(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    client.patch("/v1/me", headers=bearer(renter), json={"gender": "nonbinary"})
    lister = make_lister(db)
    for_women = put_listing(db, clock, lister, gender_preference="women")
    for_men = put_listing(db, clock, lister, gender_preference="men")

    assert set(ids(deck(client, renter))) == {str(for_women.id), str(for_men.id)}


def test_live_with_women_shows_households_of_women_and_places_with_nobody_staying(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json=search(
            clock,
            preferences=[{"field": "housemate_gender", "value": "women", "importance": "must"}],
        ),
    )
    lister = make_lister(db)
    women = put_listing(db, clock, lister, household_gender="women")
    put_listing(db, clock, lister, household_gender="men")
    put_listing(db, clock, lister, household_gender="mixed")
    whole = put_listing(
        db, clock, lister, space_type="entire_unit", housemates_staying=0, household_gender=None
    )

    assert set(ids(deck(client, renter))) == {str(women.id), str(whole.id)}


# --- Not set up yet ---------------------------------------------------------------


def test_the_deck_needs_a_search(client: TestClient, mailer: RecordingMailer) -> None:
    who = sign_in(client, mailer, "new@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)

    for path in ("/v1/deck/listings", "/v1/deck/diagnostics"):
        response = client.get(path, headers=bearer(who))
        assert response.status_code == 409
        assert response.json()["code"] == "renter_profile_incomplete"


def test_the_deck_needs_a_finished_profile(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    who = sign_in(client, mailer, "new@uw.edu")
    client.put("/v1/me/renter-profile", headers=bearer(who), json=search(clock))

    response = client.get("/v1/deck/listings", headers=bearer(who))

    assert response.status_code == 409
    assert response.json() == {
        "code": "profile_incomplete",
        "message": "Finish your profile first.",
    }


def test_signing_in_is_required(client: TestClient) -> None:
    assert client.get("/v1/deck/listings").status_code == 401
    assert client.get("/v1/deck/diagnostics").status_code == 401


# --- Diagnostics --------------------------------------------------------------------


def diagnostics(client: TestClient, who: dict) -> dict:
    response = client.get("/v1/deck/diagnostics", headers=bearer(who))
    assert response.status_code == 200, response.text
    return response.json()


def test_diagnostics_names_the_must_have_that_removes_the_most(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json=search(
            clock,
            preferences=[
                {"field": "parking", "value": True, "importance": "must"},
                {"field": "furnished", "value": True, "importance": "must"},
            ],
        ),
    )
    lister = make_lister(db)
    for _ in range(3):
        put_listing(db, clock, lister, parking=False)
    put_listing(db, clock, lister, parking=True, furnished=False)

    body = diagnostics(client, renter)

    assert deck(client, renter) == []
    assert body["in_area"] == 4
    assert body["eligible"] == 0
    assert body["top_must_have"] == {
        "field": "parking",
        "kind": "must_have",
        "removed": 3,
        "message": "3 listings don't have parking. Make it nice-to-have to see them.",
    }
    assert [item["field"] for item in body["blockers"]] == ["parking", "furnished"]


def test_diagnostics_when_nothing_is_in_the_area(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    put_listing(db, clock, make_lister(db), km_north=20)

    body = diagnostics(client, renter)

    assert body["in_area"] == 0
    assert body["top_must_have"]["field"] == "radius"
    assert body["top_must_have"]["message"] == (
        "No listings within 3.1 miles of your pin yet. Try a bigger area."
    )


def test_a_renter_without_a_gender_is_told_why_some_places_are_hidden(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    client.patch("/v1/me", headers=bearer(renter), json={"gender": None})
    lister = make_lister(db)
    put_listing(db, clock, lister, gender_preference="women")
    shown = put_listing(db, clock, lister, gender_preference="any")

    body = diagnostics(client, renter)

    assert ids(deck(client, renter)) == [str(shown.id)]
    assert body["eligible"] == 1
    assert body["top_must_have"] is None
    assert body["blockers"] == [
        {
            "field": "gender_missing",
            "kind": "lister_filter",
            "removed": 1,
            "message": (
                "1 listing has a gender preference. "
                "Add your gender in your profile to see the ones that fit you."
            ),
        }
    ]


# --- Fake data and speed ---------------------------------------------------------------


@pytest.fixture
def seeded(app, db: Session) -> seed_fake.SeedResult:
    result = seed_fake.seed_fake_data(db, today=date(2027, 1, 4), rng=random.Random(4))
    db.commit()
    return result


def test_the_seed_makes_1000_listings_and_200_renters_at_three_campuses(
    db: Session, seeded: seed_fake.SeedResult
) -> None:
    assert seeded.listings == 1_000
    assert seeded.renters == 200
    assert db.scalar(select(func.count()).select_from(Listing)) == 1_000
    assert db.scalar(select(func.count()).select_from(RenterProfile)) == 200
    domains = {email.split("@")[1] for email in seeded.renter_emails}
    assert domains == {campus.domain for campus in seed_fake.CAMPUSES}
    assert db.scalar(select(func.count()).select_from(ListingPhoto)) == 4_000


def test_running_the_seed_again_replaces_the_batch(db: Session, seeded) -> None:
    seed_fake.seed_fake_data(db, listings=30, renters=6)
    db.commit()

    assert db.scalar(select(func.count()).select_from(Listing)) == 30
    assert db.scalar(select(func.count()).select_from(RenterProfile)) == 6


def test_the_seed_never_touches_real_accounts(
    client: TestClient, renter: dict, db: Session, seeded
) -> None:
    seed_fake.remove_fake_data(db)
    db.commit()

    assert db.scalars(select(User.email)).all() == ["renter@uw.edu"]


def test_the_seed_stores_photos_when_this_server_keeps_them(app, db: Session) -> None:
    result = seed_fake.seed_fake_data(
        db, listings=6, renters=0, store=DatabaseStore(app.state.engine)
    )
    db.commit()

    assert result.photos_stored == 24
    assert db.scalar(select(func.count()).select_from(StoredFile)) == 24

    seed_fake.remove_fake_data(db)
    db.commit()
    assert db.scalar(select(func.count()).select_from(StoredFile)) == 0


def test_the_seed_works_without_its_sample_pictures(
    app, db: Session, monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
    monkeypatch.setattr(seed_fake, "PHOTO_DIR", tmp_path / "missing")

    result = seed_fake.seed_fake_data(
        db, listings=6, renters=0, store=DatabaseStore(app.state.engine)
    )

    assert result.listings == 6
    assert result.photos_stored == 0


def test_the_seed_refuses_production(capsys: pytest.CaptureFixture) -> None:
    production = Settings.model_construct(env="production")

    assert seed_fake.main([], settings=production) == 2
    assert "Refusing" in capsys.readouterr().err


def test_seeded_decks_hold_only_eligible_listings(
    client: TestClient, db: Session, seeded, clock: Clock
) -> None:
    """For many seeded renters, every listing in the deck passes every rule,
    and every eligible listing in the area is in a deck big enough to hold it."""
    for email in seeded.renter_emails[:24]:
        user = db.scalar(select(User).where(User.email == email))
        profile = db.get(RenterProfile, user.id)
        renter = Renter.from_models(user, profile)
        expected = {
            str(listing.id)
            for listing in candidates(db, renter, clock.now.date())
            if not failures(renter, listing, listing.owner.school_id)
        }
        who = signed_in_as(client, email)

        shown = deck(client, who, limit=50)

        for item in shown:
            listing = db.get(Listing, uuid.UUID(item["listing"]["id"]))
            assert not failures(renter, listing, listing.owner.school_id), item["reasons"]
        if len(expected) <= 50:
            assert set(ids(shown)) == expected
        scores = [item["score"] for item in shown]
        assert scores == sorted(scores, reverse=True)


def signed_in_as(client: TestClient, email: str) -> dict:
    """Tokens for a seeded account, without an email round trip."""
    from app.deps import get_now
    from app.services.tokens import issue_pair

    app = client.app
    with Session(app.state.engine) as session:
        user = session.scalar(select(User).where(User.email == email))
        tokens = issue_pair(app.state.settings, user.id, app.dependency_overrides[get_now]())
    return {"access_token": tokens.access_token}


def test_the_deck_answers_in_under_300_ms_with_the_seeded_data(
    client: TestClient, db: Session, seeded
) -> None:
    timings = []
    for email in seeded.renter_emails[:15]:
        who = signed_in_as(client, email)
        deck(client, who)  # warm up this renter's connection and caches
        started = time.perf_counter()
        deck(client, who)
        timings.append(time.perf_counter() - started)

    assert statistics.median(timings) < 0.3, f"median {statistics.median(timings):.3f}s"
    assert max(timings) < 0.6, f"slowest {max(timings):.3f}s"
