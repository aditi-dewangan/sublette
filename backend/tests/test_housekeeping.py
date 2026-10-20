"""Listing expiry and renewal, duplicate photos, abandoned uploads, and the
background thread that runs them."""

import threading
import time
import uuid
from datetime import timedelta

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from app.models import Listing, ListingPhoto, RateLimitHit, Report, Upload
from app.services import housekeeping
from app.services.housekeeping import Housekeeper, run_once
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_chat import RecordingPush, device, draft_for
from tests.test_deck import deck, ids, make_lister, make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, user_of


@pytest.fixture
def push(app: FastAPI) -> RecordingPush:
    recording = RecordingPush()
    app.state.push.sender = recording
    return recording


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


def run(app: FastAPI, clock: Clock) -> housekeeping.Summary:
    summary = run_once(app.state.engine, app.state.storage, app.state.push, clock.now)
    app.state.push.drain()
    return summary


def publish(client: TestClient, who: dict, listing_id) -> dict:
    return ok(
        client.post(
            f"/v1/listings/{listing_id}/status", headers=bearer(who), json={"status": "active"}
        )
    )


# --- Expiry and renewal ------------------------------------------------------------


def test_a_listing_stays_live_until_its_move_in_date(
    client: TestClient, lister: dict, db: Session, clock: Clock
) -> None:
    draft = draft_for(db, clock, user_of(db, lister))  # moves in 30 days from now

    published = publish(client, lister, draft.id)

    assert published["expires_on"] == str(draft.start_date)


def test_a_listing_starting_soon_stays_live_two_weeks(
    client: TestClient, lister: dict, db: Session, clock: Clock
) -> None:
    today = clock.now.date()
    soon = draft_for(
        db,
        clock,
        user_of(db, lister),
        start_date=today + timedelta(days=2),
        end_date=today + timedelta(days=60),
    )
    short = draft_for(
        db, clock, user_of(db, lister), start_date=today, end_date=today + timedelta(days=5)
    )

    assert publish(client, lister, soon.id)["expires_on"] == str(today + timedelta(days=14))
    assert publish(client, lister, short.id)["expires_on"] == str(today + timedelta(days=5))


def test_only_the_owner_sees_the_expiry_date(
    client: TestClient, lister: dict, renter: dict, db: Session, clock: Clock
) -> None:
    draft = draft_for(db, clock, user_of(db, lister))
    publish(client, lister, draft.id)

    seen = ok(client.get(f"/v1/listings/{draft.id}", headers=bearer(renter)))

    assert seen["expires_on"] is None


def test_an_expired_listing_leaves_the_deck_on_the_day_and_its_lister_is_asked_to_renew(
    client: TestClient,
    app: FastAPI,
    push: RecordingPush,
    lister: dict,
    renter: dict,
    db: Session,
    clock: Clock,
    mailer: RecordingMailer,
) -> None:
    draft = draft_for(db, clock, user_of(db, lister))
    publish(client, lister, draft.id)
    device(client, lister, "cc" * 32)
    assert ids(deck(client, renter)) == [str(draft.id)]

    clock.advance(days=31)  # past the move-in date
    renter = sign_in(client, mailer, "renter@uw.edu")

    # Hidden at once, before housekeeping has run.
    assert deck(client, renter) == []
    summary = run(app, clock)

    assert summary.expired == [draft.id]
    db.expire_all()
    assert db.get(Listing, draft.id).status == "expired"
    [(_, note)] = push.sent
    assert note.data == {"kind": "listing_expired", "listing_id": str(draft.id), "role": "lister"}
    assert run(app, clock).expired == [], "a second run changes nothing"


def test_renewing_an_expired_listing_puts_it_back_for_two_weeks(
    client: TestClient, app: FastAPI, mailer: RecordingMailer, db: Session, clock: Clock, push
) -> None:
    lister = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(lister), json=COMPLETE_PROFILE)
    draft = draft_for(db, clock, user_of(db, lister))
    publish(client, lister, draft.id)
    clock.advance(days=31)
    run(app, clock)
    lister = sign_in(client, mailer, "lister@uw.edu")

    renewed = publish(client, lister, draft.id)

    assert renewed["status"] == "active"
    assert renewed["expires_on"] == str(clock.now.date() + timedelta(days=14))


def test_publishing_a_live_listing_again_renews_it(
    client: TestClient, lister: dict, db: Session, clock: Clock, mailer: RecordingMailer
) -> None:
    today = clock.now.date()
    draft = draft_for(
        db, clock, user_of(db, lister), start_date=today, end_date=today + timedelta(days=90)
    )
    publish(client, lister, draft.id)
    clock.advance(days=10)
    lister = sign_in(client, mailer, "lister@uw.edu")

    again = publish(client, lister, draft.id)

    assert again["expires_on"] == str(clock.now.date() + timedelta(days=14))


def test_editing_a_live_listing_renews_it(
    client: TestClient, lister: dict, db: Session, clock: Clock, mailer: RecordingMailer
) -> None:
    today = clock.now.date()
    draft = draft_for(
        db, clock, user_of(db, lister), start_date=today, end_date=today + timedelta(days=90)
    )
    publish(client, lister, draft.id)
    clock.advance(days=10)
    lister = sign_in(client, mailer, "lister@uw.edu")

    edited = client.patch(
        f"/v1/listings/{draft.id}", headers=bearer(lister), json={"rent_cents": 95_000}
    ).json()

    assert edited["expires_on"] == str(clock.now.date() + timedelta(days=14))


def test_a_listing_past_its_move_out_date_expires_without_a_renewal_push(
    client: TestClient, app: FastAPI, push: RecordingPush, lister: dict, db: Session, clock
) -> None:
    owner = user_of(db, lister)
    over = put_listing(
        db,
        clock,
        owner,
        end_date=clock.now.date() - timedelta(days=1),
        start_date=clock.now.date() - timedelta(days=60),
    )
    device(client, lister, "dd" * 32)

    assert run(app, clock).expired == [over.id]
    assert push.sent == []


def test_filled_drafts_and_removed_listings_never_expire(
    app: FastAPI, lister: dict, db: Session, clock: Clock
) -> None:
    owner = user_of(db, lister)
    past = dict(
        end_date=clock.now.date() - timedelta(days=1),
        start_date=clock.now.date() - timedelta(days=60),
    )
    for status in ("filled", "draft", "removed"):
        put_listing(db, clock, owner, status=status, **past)

    assert run(app, clock).expired == []


# --- Duplicate photos ----------------------------------------------------------------


def stored(app: FastAPI, owner_id: uuid.UUID, data: bytes) -> str:
    key = f"listings/{owner_id}/{uuid.uuid4().hex}.jpg"
    app.state.storage.store.put(key, "image/jpeg", data)
    return key


def listing_with_photos(db, clock, owner, keys: list[str], **changes) -> Listing:
    photos = [ListingPhoto(key=key, position=index) for index, key in enumerate(keys)]
    return put_listing(db, clock, owner, photos=photos, **changes)


def test_one_photo_on_two_peoples_listings_is_flagged(
    app: FastAPI, db: Session, clock: Clock
) -> None:
    first, second = make_lister(db), make_lister(db)
    original = listing_with_photos(db, clock, first, [stored(app, first.id, b"room photo")])
    copy = listing_with_photos(db, clock, second, [stored(app, second.id, b"room photo")])

    summary = run(app, clock)

    assert summary.photos_checked == 2
    assert set(summary.flagged) == {original.id, copy.id}
    flags = db.scalars(select(Report)).all()
    assert {flag.reason for flag in flags} == {"duplicate_photo"}
    assert {flag.subject_id for flag in flags} == {first.id, second.id}
    assert run(app, clock).flagged == [], "flagged once"


def test_reusing_your_own_photos_is_fine(app: FastAPI, db: Session, clock: Clock) -> None:
    owner = make_lister(db)
    listing_with_photos(db, clock, owner, [stored(app, owner.id, b"my room")])
    listing_with_photos(db, clock, owner, [stored(app, owner.id, b"my room")])

    assert run(app, clock).flagged == []


def test_draft_photos_are_not_checked_until_published(
    app: FastAPI, db: Session, clock: Clock
) -> None:
    first, second = make_lister(db), make_lister(db)
    listing_with_photos(db, clock, first, [stored(app, first.id, b"room")])
    listing_with_photos(db, clock, second, [stored(app, second.id, b"room")], status="draft")

    assert run(app, clock).flagged == []


def test_a_photo_storage_cant_read_is_tried_again_later(
    app: FastAPI, db: Session, clock: Clock
) -> None:
    owner = make_lister(db)
    missing = f"listings/{owner.id}/{uuid.uuid4().hex}.jpg"
    listing_with_photos(db, clock, owner, [missing])

    assert run(app, clock).photos_checked == 0
    assert db.scalar(select(ListingPhoto.content_hash)) is None


def test_photo_storage_failing_does_not_stop_housekeeping(
    app: FastAPI, db: Session, clock: Clock, monkeypatch
) -> None:
    owner = make_lister(db)
    listing_with_photos(db, clock, owner, [stored(app, owner.id, b"x")])

    def broken(key):
        raise OSError("disk gone")

    monkeypatch.setattr(app.state.storage.store, "get", broken)

    assert run(app, clock).photos_checked == 0


# --- Abandoned uploads ---------------------------------------------------------------


def presign(client: TestClient, who: dict, purpose: str = "listing_photo") -> str:
    response = client.post(
        "/v1/uploads/presign",
        headers=bearer(who),
        json={"purpose": purpose, "content_type": "image/jpeg"},
    )
    assert response.status_code == 200, response.text
    return response.json()["key"]


def test_photos_never_attached_are_deleted_after_a_day(
    client: TestClient, app: FastAPI, lister: dict, db: Session, clock: Clock
) -> None:
    abandoned = presign(client, lister)
    attached = presign(client, lister)
    profile = presign(client, lister, "profile_photo")
    for key in (abandoned, attached, profile):
        app.state.storage.store.put(key, "image/jpeg", b"photo")
    client.post("/v1/listings", headers=bearer(lister), json={"photo_keys": [attached]})
    client.patch("/v1/me", headers=bearer(lister), json={"photo_key": profile})

    assert run(app, clock).uploads_deleted == 0, "not yet a day old"
    clock.advance(days=1, seconds=1)
    summary = run(app, clock)

    assert summary.uploads_deleted == 1
    assert app.state.storage.store.get(abandoned) is None
    assert app.state.storage.store.get(attached) is not None
    assert app.state.storage.store.get(profile) is not None
    assert db.scalars(select(Upload)).all() == []


def test_deleting_an_account_deletes_its_abandoned_uploads(
    client: TestClient, app: FastAPI, lister: dict
) -> None:
    key = presign(client, lister)
    app.state.storage.store.put(key, "image/jpeg", b"photo")

    client.delete("/v1/me", headers=bearer(lister))

    assert app.state.storage.store.get(key) is None


def test_old_rate_limit_counts_are_pruned(app: FastAPI, db: Session, clock: Clock) -> None:
    db.add(RateLimitHit(bucket="old", created_at=clock.now - timedelta(days=3)))
    db.add(RateLimitHit(bucket="new", created_at=clock.now))
    db.commit()

    run(app, clock)

    assert db.scalars(select(RateLimitHit.bucket)).all() == ["new"]


# --- Running it --------------------------------------------------------------------------


def test_only_one_process_runs_housekeeping_at_a_time(app: FastAPI, clock: Clock) -> None:
    with app.state.engine.connect() as other_process:
        other_process.execute(text("SELECT pg_advisory_lock(:id)"), {"id": housekeeping.LOCK_ID})
        assert run(app, clock).ran is False
        other_process.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": housekeeping.LOCK_ID})
    assert run(app, clock).ran is True


def test_the_background_thread_keeps_going_after_a_failure(monkeypatch) -> None:
    calls = []
    third = threading.Event()

    def flaky(*args):
        calls.append(args)
        if len(calls) == 1:
            raise RuntimeError("database down")
        if len(calls) >= 3:
            third.set()
        return housekeeping.Summary()

    monkeypatch.setattr(housekeeping, "run_once", flaky)
    keeper = Housekeeper(None, None, None, every_s=0.01)

    keeper.start()
    assert third.wait(5)
    keeper.stop()

    count = len(calls)
    time.sleep(0.05)
    assert len(calls) == count, "stopped"


def test_tests_and_the_off_switch_turn_the_thread_off() -> None:
    from app.config import Settings

    assert Settings(env="test").housekeeping_every_s == 0
    assert Settings(env="local").housekeeping_every_s == 600
    assert Settings(env="local", housekeeping_interval_s=0).housekeeping_every_s == 0
