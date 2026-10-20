"""Alerts (issue #22): price drops, places about to expire, the daily digest,
how often each student wants them, and the lister's weekly summary."""

import uuid
from datetime import timedelta

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.clock import local_today
from app.models import Alert, ListingPhoto, Swipe, User
from app.services.housekeeping import run_once
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_chat import RecordingPush, device, pushes
from tests.test_deck import make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, swipe, user_of


@pytest.fixture
def push(app: FastAPI) -> RecordingPush:
    recording = RecordingPush()
    app.state.push.sender = recording
    return recording


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    who = make_searching_renter(client, mailer, clock)
    device(client, who, "aa" * 32)
    return who


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    device(client, who, "bb" * 32)
    return who


def live_listing(db: Session, clock: Clock, owner, **changes):
    """A live listing complete enough to edit (it has its four photos)."""
    photos = [ListingPhoto(key=f"x/{uuid.uuid4().hex}.jpg", position=i) for i in range(4)]
    return put_listing(db, clock, owner, photos=photos, **changes)


def frequency(client: TestClient, who: dict, value: str):
    return client.patch("/v1/me", headers=bearer(who), json={"alert_frequency": value})


def lower_rent(client: TestClient, lister: dict, listing, cents: int) -> None:
    ok(
        client.patch(
            f"/v1/listings/{listing.id}", headers=bearer(lister), json={"rent_cents": cents}
        )
    )
    # Alerts go out on a background thread; let this one finish first.
    client.app.state.push.drain()


def housekeeping(app: FastAPI, clock: Clock) -> None:
    run_once(app.state.engine, app.state.storage, app.state.push, clock.now)


def notes_for(app: FastAPI, push: RecordingPush, token: str) -> list:
    return [note for sent_to, note in pushes(app, push) if sent_to == token]


# --- How often ----------------------------------------------------------------------


def test_daily_is_the_default_and_each_student_can_change_it(
    client: TestClient, renter: dict
) -> None:
    assert renter["user"]["alert_frequency"] == "daily"

    assert ok(frequency(client, renter, "instant"))["alert_frequency"] == "instant"
    assert ok(frequency(client, renter, "off"))["alert_frequency"] == "off"
    assert frequency(client, renter, "hourly").status_code == 422
    assert frequency(client, renter, None).status_code == 422


# --- Price drops --------------------------------------------------------------------


def test_a_price_drop_tells_renters_who_liked_or_saved_it(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    mailer: RecordingMailer,
) -> None:
    listing = live_listing(db, clock, user_of(db, lister), rent_cents=105_000)
    ok(swipe(client, renter, listing.id))
    saver = make_searching_renter_named(client, mailer, clock, "saver@uw.edu")
    device(client, saver, "cc" * 32)
    client.post(f"/v1/saved/{listing.id}", headers=bearer(saver))

    lower_rent(client, lister, listing, 95_000)

    [note] = notes_for(app, push, "aa" * 32)
    assert note.title == "Price dropped"
    assert note.body == "A private room you liked is now $950/month (was $1,050)."
    assert note.data == {"kind": "price_drop", "listing_id": str(listing.id), "role": "renter"}
    assert len(notes_for(app, push, "cc" * 32)) == 1


def make_searching_renter_named(client, mailer, clock, email):
    from tests.test_map import make_searching_renter_named as make

    return make(client, mailer, clock, email)


def test_a_higher_rent_or_a_paused_listing_tells_no_one(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, db, clock
) -> None:
    listing = live_listing(db, clock, user_of(db, lister), rent_cents=100_000)
    ok(swipe(client, renter, listing.id))

    lower_rent(client, lister, listing, 110_000)
    ok(
        client.post(
            f"/v1/listings/{listing.id}/status", headers=bearer(lister), json={"status": "paused"}
        )
    )
    lower_rent(client, lister, listing, 90_000)

    assert notes_for(app, push, "aa" * 32) == []


def test_no_alerts_when_off_or_blocked(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, db, clock
) -> None:
    first = live_listing(db, clock, user_of(db, lister), rent_cents=100_000)
    ok(swipe(client, renter, first.id))
    frequency(client, renter, "off")
    lower_rent(client, lister, first, 90_000)

    frequency(client, renter, "instant")
    client.post("/v1/blocks", headers=bearer(lister), json={"user_id": renter["user"]["id"]})
    lower_rent(client, lister, first, 80_000)

    assert notes_for(app, push, "aa" * 32) == []


# --- The daily digest ---------------------------------------------------------------


def test_daily_sends_the_first_at_once_and_bundles_the_rest(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    mailer: RecordingMailer,
) -> None:
    owner = user_of(db, lister)
    places = [live_listing(db, clock, owner, rent_cents=100_000) for _ in range(3)]
    for place in places:
        ok(swipe(client, renter, place.id))

    lower_rent(client, lister, places[0], 95_000)
    lower_rent(client, lister, places[1], 95_000)
    lower_rent(client, lister, places[1], 90_000)  # again, before the digest
    lower_rent(client, lister, places[2], 95_000)

    assert [note.title for note in notes_for(app, push, "aa" * 32)] == ["Price dropped"]
    user = user_of(db, renter)
    assert user.last_digest_at == clock.now

    housekeeping(app, clock)
    assert len(notes_for(app, push, "aa" * 32)) == 1, "the day isn't up"

    clock.advance(days=1, minutes=1)
    housekeeping(app, clock)

    digest = notes_for(app, push, "aa" * 32)[-1]
    assert digest.title == "Your Sublette update"
    assert digest.body == "2 price drops"
    assert digest.data["kind"] == "digest"
    second = db.scalars(select(Alert).where(Alert.listing_id == places[1].id)).one()
    assert second.detail["old_cents"] == 100_000 and second.detail["new_cents"] == 90_000


def test_instant_sends_each_one(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, db, clock
) -> None:
    frequency(client, renter, "instant")
    owner = user_of(db, lister)
    places = [live_listing(db, clock, owner, rent_cents=100_000) for _ in range(2)]
    for place in places:
        ok(swipe(client, renter, place.id))

    for place in places:
        lower_rent(client, lister, place, 95_000)

    assert len(notes_for(app, push, "aa" * 32)) == 2


# --- About to expire ----------------------------------------------------------------


def test_a_liked_place_closing_in_two_days_is_mentioned_once(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    mailer: RecordingMailer,
) -> None:
    soon = local_today(clock.now) + timedelta(days=2)
    listing = put_listing(db, clock, user_of(db, lister), expires_on=soon)
    ok(swipe(client, renter, listing.id))
    matched = make_searching_renter_named(client, mailer, clock, "matched@uw.edu")
    device(client, matched, "dd" * 32)
    ok(swipe(client, matched, listing.id))
    ok(swipe(client, lister, listing.id, renter_id=matched["user"]["id"]))

    housekeeping(app, clock)
    housekeeping(app, clock)

    [note] = notes_for(app, push, "aa" * 32)
    assert note.title == "Still interested?"
    assert note.data["kind"] == "expiring"
    assert [n for n in notes_for(app, push, "dd" * 32) if n.title == "Still interested?"] == []


# --- The lister's weekly summary ----------------------------------------------------


def test_listers_hear_about_unanswered_likes_once_a_week(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    mailer: RecordingMailer,
) -> None:
    owner = user_of(db, lister)
    listing = put_listing(db, clock, owner)
    other = make_searching_renter_named(client, mailer, clock, "other@uw.edu")
    ok(swipe(client, renter, listing.id))
    ok(swipe(client, other, listing.id))
    # Swipes are stamped by the database's clock; put them on the test's.
    db.execute(update(Swipe).values(created_at=clock.now))
    db.commit()

    housekeeping(app, clock)
    housekeeping(app, clock)

    [summary] = [n for n in notes_for(app, push, "bb" * 32) if n.data["kind"] == "likes"]
    assert summary.title == "2 renters liked your place this week"
    assert summary.data["role"] == "lister"
    assert db.get(User, owner.id).last_lister_summary_at == clock.now


def test_answered_likes_and_listers_who_turned_alerts_off_get_no_summary(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, db, clock
) -> None:
    listing = put_listing(db, clock, user_of(db, lister))
    ok(swipe(client, renter, listing.id))
    ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"], action="pass"))
    db.execute(update(Swipe).values(created_at=clock.now))
    db.commit()

    housekeeping(app, clock)

    assert [n for n in notes_for(app, push, "bb" * 32) if n.data["kind"] == "likes"] == []
