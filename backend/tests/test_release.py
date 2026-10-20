"""Analytics, crash reports, referral codes and the share page (phase 9)."""

import re
import uuid
from datetime import timedelta

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import CrashReport, Event, Listing, Swipe, User
from app.models.analytics import CODE_ALPHABET
from app.services.analytics import metrics
from tests.conftest import Clock, RecordingMailer, admin_post, bearer, settings_with, sign_in
from tests.test_chat import draft_for
from tests.test_deck import make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, swipe, user_of


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


def events(db: Session, name: str | None = None) -> list[Event]:
    db.expire_all()
    query = select(Event).order_by(Event.id)
    if name:
        query = query.where(Event.name == name)
    return list(db.scalars(query))


def publish(client: TestClient, who: dict, listing_id) -> dict:
    return ok(
        client.post(
            f"/v1/listings/{listing_id}/status", headers=bearer(who), json={"status": "active"}
        )
    )


# --- The funnel --------------------------------------------------------------------------


def test_each_funnel_step_is_recorded_once_where_it_happens(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    draft = draft_for(db, clock, user_of(db, lister))
    publish(client, lister, draft.id)
    clock.advance(days=3, hours=12)
    renter_again = sign_in(client, client.app.state.email_sender, "renter@uw.edu")
    lister_again = sign_in(client, client.app.state.email_sender, "lister@uw.edu")
    ok(swipe(client, renter_again, draft.id))
    match = ok(swipe(client, lister_again, draft.id, renter_id=renter["user"]["id"]))["match"]
    client.patch("/v1/me", headers=bearer(renter_again), json={"bio": "Hi"})  # not a new step
    clock.advance(days=2)
    lister_again = sign_in(client, client.app.state.email_sender, "lister@uw.edu")
    client.post(f"/v1/matches/{match['id']}/filled", headers=bearer(lister_again))

    names = [event.name for event in events(db)]
    renter_id, lister_id = uuid.UUID(renter["user"]["id"]), uuid.UUID(lister["user"]["id"])
    assert names.count("signed_up") == 2
    assert names.count("profile_completed") == 2
    assert {e.user_id for e in events(db, "first_swipe")} == {renter_id, lister_id}
    assert {e.user_id for e in events(db, "first_match")} == {renter_id, lister_id}
    [published] = events(db, "listing_published")
    [first_match] = events(db, "listing_first_match")
    [filled] = events(db, "listing_filled")
    assert published.listing_id == first_match.listing_id == filled.listing_id == draft.id
    assert first_match.value == 3.5
    assert filled.value == 5.5


def test_filling_from_the_listing_screen_counts_too(
    client: TestClient, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, user_of(db, lister))

    ok(
        client.post(
            f"/v1/listings/{listing.id}/status", headers=bearer(lister), json={"status": "filled"}
        )
    )

    assert [e.listing_id for e in events(db, "listing_filled")] == [listing.id]


def test_deleting_an_account_keeps_its_events_without_a_name(
    client: TestClient, lister: dict, db: Session
) -> None:
    client.delete("/v1/me", headers=bearer(lister))

    rows = events(db)
    assert rows and all(row.user_id is None for row in rows)


# --- What the app sends ------------------------------------------------------------------


def test_the_app_reports_opens_and_feature_use(
    client: TestClient, renter: dict, db: Session
) -> None:
    opened = client.post("/v1/events", headers=bearer(renter), json={"name": "app_opened"})
    used = client.post(
        "/v1/events", headers=bearer(renter), json={"name": "feature_used", "feature": "map"}
    )
    no_feature = client.post("/v1/events", headers=bearer(renter), json={"name": "feature_used"})
    unknown = client.post(
        "/v1/events", headers=bearer(renter), json={"name": "feature_used", "feature": "hack"}
    )
    funnel = client.post("/v1/events", headers=bearer(renter), json={"name": "first_match"})

    assert opened.status_code == used.status_code == 204
    assert no_feature.status_code == unknown.status_code == funnel.status_code == 422
    assert [e.detail for e in events(db, "feature_used")] == ["map"]


def test_app_events_are_rate_limited(client: TestClient, app: FastAPI, renter: dict) -> None:
    settings_with(app, events_per_hour=1)

    first = client.post("/v1/events", headers=bearer(renter), json={"name": "app_opened"})
    second = client.post("/v1/events", headers=bearer(renter), json={"name": "app_opened"})

    assert first.status_code == 204 and second.status_code == 429


CRASH = {"kind": "crash", "app_version": "1.0 (3)", "os_version": "iOS 18.1", "payload": "{}"}


def test_crash_reports_are_stored(client: TestClient, renter: dict, db: Session) -> None:
    response = client.post("/v1/diagnostics", headers=bearer(renter), json=CRASH)
    huge = client.post(
        "/v1/diagnostics", headers=bearer(renter), json={**CRASH, "payload": "x" * 70_000}
    )

    assert response.status_code == 204
    assert huge.status_code == 422
    [stored] = db.scalars(select(CrashReport)).all()
    assert stored.kind == "crash" and stored.app_version == "1.0 (3)"


def test_crash_reports_are_rate_limited(client: TestClient, app: FastAPI, renter: dict) -> None:
    settings_with(app, crash_reports_per_day=1)

    client.post("/v1/diagnostics", headers=bearer(renter), json=CRASH)

    assert client.post("/v1/diagnostics", headers=bearer(renter), json=CRASH).status_code == 429


# --- The admin numbers -------------------------------------------------------------------


def test_metrics_count_the_funnel_unanswered_likes_and_crash_free_sessions(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(db, clock, user_of(db, lister))
    ok(swipe(client, renter, listing.id))
    for _ in range(4):
        client.post("/v1/events", headers=bearer(renter), json={"name": "app_opened"})
    client.post("/v1/diagnostics", headers=bearer(renter), json=CRASH)
    # Swipes are stamped by the database's clock; put this one on the test's.
    db.execute(update(Swipe).values(created_at=clock.now))
    db.commit()
    clock.advance(days=8)

    found = metrics(db, clock.now)

    assert dict(found["funnel"])["signed_up"] == 2
    assert found["likes_without_response"] == 1 and found["likes_old_enough"] == 1
    assert found["sessions"] == 4 and found["crashes"] == 1
    assert found["crash_free_percent"] == 75.0


def test_the_numbers_page_shows_them(
    client: TestClient,
    app: FastAPI,
    admin: dict,
    renter: dict,
) -> None:
    client.post("/v1/events", headers=bearer(renter), json={"name": "app_opened"})
    client.post("/v1/diagnostics", headers=bearer(renter), json={**CRASH, "payload": "<boom>"})

    page = client.get("/admin/metrics", headers=admin)

    assert page.status_code == 200
    assert "Signed up" in page.text and "Crash-free sessions" in page.text
    assert "0.0%" in page.text
    assert "&lt;boom&gt;" in page.text


# --- Referral codes ----------------------------------------------------------------------


def test_every_account_has_its_own_easy_to_type_code(
    client: TestClient, mailer: RecordingMailer
) -> None:
    codes = {sign_in(client, mailer, f"s{n}@uw.edu")["user"]["referral_code"] for n in range(5)}

    assert len(codes) == 5
    for code in codes:
        assert re.fullmatch(f"[{CODE_ALPHABET}]{{7}}", code)


def refer(client: TestClient, who: dict, code: str):
    return client.post("/v1/me/referral", headers=bearer(who), json={"code": code})


def test_a_new_lister_can_add_a_friends_code_once(
    client: TestClient, renter: dict, lister: dict, db: Session
) -> None:
    code = renter["user"]["referral_code"]
    spaced = f" {code[:3].lower()}-{code[3:]} "

    added = refer(client, lister, spaced)
    again = refer(client, lister, code)

    assert added.status_code == 200 and added.json()["referred"] is True
    assert again.json()["code"] == "referral_already_used"
    assert user_of(db, lister).referred_by_id == uuid.UUID(renter["user"]["id"])


def test_referral_codes_that_cant_be_used(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    assert refer(client, lister, "NOPE234").json()["code"] == "referral_not_found"
    assert refer(client, lister, lister["user"]["referral_code"]).json()["code"] == (
        "own_referral_code"
    )
    put_listing(db, clock, user_of(db, lister))
    late = refer(client, lister, renter["user"]["referral_code"])
    assert late.json()["code"] == "referral_too_late"


def test_referrals_appear_for_payment_after_seven_days_live(
    client: TestClient,
    app: FastAPI,
    admin: dict,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
) -> None:
    refer(client, lister, renter["user"]["referral_code"])
    put_listing(db, clock, user_of(db, lister), published_at=clock.now - timedelta(days=3))

    early = client.get("/admin/referrals", headers=admin).text
    assert "not 7 days yet" in early

    db.execute(update(Listing).values(published_at=clock.now - timedelta(days=8)))
    db.commit()
    due = client.get("/admin/referrals", headers=admin).text
    assert "Mark reward paid" in due

    admin_post(client, app, admin, f"/admin/referrals/{lister['user']['id']}/paid")
    db.expire_all()
    assert user_of(db, lister).referral_paid_at == clock.now
    assert "Mark reward paid" not in client.get("/admin/referrals", headers=admin).text


# --- The share page ----------------------------------------------------------------------


def test_a_shared_listing_shows_only_what_any_renter_sees(
    client: TestClient, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(
        db,
        clock,
        user_of(db, lister),
        address="1 Private Way",
        latitude=47.6612345,
        rent_cents=95_000,
    )

    page = client.get(f"/l/{listing.id}")

    assert page.status_code == 200
    assert "Private room · $950/month" in page.text
    assert "og:title" in page.text and f"/l/{listing.id}" in page.text
    for secret in ("1 Private Way", "47.6612345", "Aditi", "lister@uw.edu"):
        assert secret not in page.text


@pytest.mark.parametrize("status", ["draft", "paused", "filled", "expired", "removed"])
def test_a_listing_that_isnt_live_isnt_shown(
    client: TestClient, lister: dict, db: Session, clock: Clock, status: str
) -> None:
    listing = put_listing(db, clock, user_of(db, lister), status=status)

    page = client.get(f"/l/{listing.id}")

    assert page.status_code == 404
    assert "isn't available" in page.text


def test_a_suspended_listers_listing_isnt_shown(
    client: TestClient, lister: dict, db: Session, clock: Clock
) -> None:
    owner = user_of(db, lister)
    listing = put_listing(db, clock, owner)
    db.execute(update(User).where(User.id == owner.id).values(status="suspended"))
    db.commit()

    assert client.get(f"/l/{listing.id}").status_code == 404
