"""Fixes from the final review of phases 7 to 10."""

import threading
import uuid
from datetime import UTC, datetime, timedelta

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.clock import local_today
from app.models import DeviceToken, Listing, ListingPhoto, Report, User
from app.schemas.safety import ReportIn
from app.services import housekeeping
from app.services.safety import report as file_report
from tests.conftest import Clock, RecordingMailer, admin_post, bearer, sign_in
from tests.test_chat import device, live, receive
from tests.test_deck import deck, ids, make_lister, make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, swipe, user_of


def renter_and_lister(client, mailer, clock):
    renter = make_searching_renter(client, mailer, clock)
    lister = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(lister), json=COMPLETE_PROFILE)
    return renter, lister


def test_a_resent_swipe_after_a_block_hands_back_no_match(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter, lister = renter_and_lister(client, mailer, clock)
    listing = put_listing(db, clock, user_of(db, lister), address="1 Private Way")
    swipe_id = str(uuid.uuid4())
    ok(swipe(client, renter, listing.id, swipe_id=swipe_id))
    ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))
    client.post("/v1/blocks", headers=bearer(lister), json={"user_id": renter["user"]["id"]})

    again = ok(swipe(client, renter, listing.id, swipe_id=swipe_id))

    assert again["match"] is None
    assert "1 Private Way" not in str(again)


def test_a_plus_address_is_the_same_account(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    first = sign_in(client, mailer, "alice@uw.edu")
    clock.advance(seconds=31)  # the wait between codes
    response = client.post("/v1/auth/request-code", json={"email": "Alice+again@uw.edu"})
    assert response.status_code == 200
    code = mailer.code_for("alice@uw.edu")
    second = client.post("/v1/auth/verify", json={"email": "alice+again@uw.edu", "code": code})

    assert second.json()["user"]["id"] == first["user"]["id"]


def test_a_suspended_student_cant_return_with_a_plus_address(
    client: TestClient, app: FastAPI, admin: dict, mailer: RecordingMailer, clock: Clock
) -> None:
    alice = sign_in(client, mailer, "alice@uw.edu")
    admin_post(client, app, admin, f"/admin/users/{alice['user']['id']}/suspend", reason="spam")
    clock.advance(seconds=31)

    client.post("/v1/auth/request-code", json={"email": "alice+2@uw.edu"})
    response = client.post(
        "/v1/auth/verify", json={"email": "alice+2@uw.edu", "code": mailer.code_for("alice@uw.edu")}
    )

    assert response.status_code == 403


def test_suspending_forgets_the_phones_push_tokens(
    client: TestClient, app: FastAPI, admin: dict, mailer: RecordingMailer, db: Session
) -> None:
    alice = sign_in(client, mailer, "alice@uw.edu")
    device(client, alice, "ab" * 32)

    admin_post(client, app, admin, f"/admin/users/{alice['user']['id']}/suspend", reason="spam")

    assert db.scalars(select(DeviceToken)).all() == []


def test_the_admin_page_cant_be_framed_or_bounced_elsewhere(
    client: TestClient, app: FastAPI, admin: dict, mailer: RecordingMailer
) -> None:
    alice = sign_in(client, mailer, "alice@uw.edu")
    page = client.get("/admin", headers=admin)

    assert page.headers["X-Frame-Options"] == "DENY"
    assert "frame-ancestors 'none'" in page.headers["Content-Security-Policy"]
    bounced = admin_post(
        client,
        app,
        {**admin, "Referer": "https://evil.example/admin?x=1"},
        f"/admin/users/{alice['user']['id']}/unsuspend",
    )
    assert bounced.headers["location"] == "/admin?x=1"


def test_a_suspended_listers_listing_is_hidden_except_from_their_match(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter, lister = renter_and_lister(client, mailer, clock)
    other = sign_in(client, mailer, "other@uw.edu")
    owner = user_of(db, lister)
    matched = put_listing(db, clock, owner)
    saved = put_listing(db, clock, owner)
    ok(swipe(client, renter, matched.id))
    ok(swipe(client, lister, matched.id, renter_id=renter["user"]["id"]))
    client.post(f"/v1/saved/{saved.id}", headers=bearer(renter))
    db.execute(update(User).where(User.id == owner.id).values(status="suspended"))
    db.commit()

    assert client.get(f"/v1/listings/{saved.id}", headers=bearer(other)).status_code == 404
    assert ok(client.get("/v1/saved", headers=bearer(renter)))["items"] == []
    assert client.get(f"/v1/listings/{matched.id}", headers=bearer(renter)).status_code == 200
    assert client.post(f"/v1/saved/{saved.id}", headers=bearer(other)).status_code == 404


def test_a_blocked_listers_listing_cant_be_saved(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter, lister = renter_and_lister(client, mailer, clock)
    listing = put_listing(db, clock, user_of(db, lister))
    client.post("/v1/blocks", headers=bearer(lister), json={"user_id": renter["user"]["id"]})

    assert client.post(f"/v1/saved/{listing.id}", headers=bearer(renter)).status_code == 404


def test_the_same_report_sent_twice_at_once_is_filed_once(
    app: FastAPI, client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter, lister = renter_and_lister(client, mailer, clock)
    reporter_id = uuid.UUID(renter["user"]["id"])
    body = ReportIn(target="user", id=uuid.UUID(lister["user"]["id"]), reason="scam")
    start = threading.Barrier(6)
    errors = []

    def send() -> None:
        with Session(app.state.engine) as session:
            user = session.get(User, reporter_id)
            start.wait()
            try:
                file_report(session, app.state.settings, user, body, clock.now)
            except Exception as error:
                errors.append(error)

    threads = [threading.Thread(target=send) for _ in range(6)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert len(db.scalars(select(Report)).all()) == 1


def test_a_listing_ending_today_stays_up_until_the_day_is_over_in_the_us(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter, lister = renter_and_lister(client, mailer, clock)
    listing = put_listing(db, clock, user_of(db, lister))
    # 4 am UTC the day after it ends: still the last evening on the West Coast.
    clock.now = datetime.combine(listing.end_date + timedelta(days=1), datetime.min.time(), UTC)
    clock.advance(hours=4)
    renter = sign_in(client, mailer, "renter@uw.edu")
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json={
            **ok(client.get("/v1/me/renter-profile", headers=bearer(renter))),
            "start_date": str(listing.end_date - timedelta(days=5)),
            "end_date": str(listing.end_date),
        },
    )

    assert local_today(clock.now) == listing.end_date
    assert str(listing.id) in ids(deck(client, renter))


def test_the_share_page_hides_a_listing_whose_date_has_passed(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    lister = sign_in(client, mailer, "lister@uw.edu")
    listing = put_listing(
        db, clock, user_of(db, lister), expires_on=clock.now.date() - timedelta(days=2)
    )

    assert client.get(f"/l/{listing.id}").status_code == 404


def test_the_assistant_never_sees_distances_from_the_pin(
    client: TestClient, app: FastAPI, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    from tests.test_assistant import FakeModel

    model = FakeModel()
    app.state.language_model = model
    renter, lister = renter_and_lister(client, mailer, clock)
    put_listing(db, clock, user_of(db, lister))

    ok(client.post("/v1/assistant/query", headers=bearer(renter), json={"message": "anything"}))

    assert "miles" not in model.prompts[-1][1] and "pin" not in model.prompts[-1][1]


def test_a_model_answer_with_a_list_for_a_field_falls_back_instead_of_failing(
    client: TestClient, app: FastAPI, mailer: RecordingMailer, clock: Clock
) -> None:
    from tests.test_assistant import FakeModel

    model = FakeModel()
    model.understanding = {
        "preferences": [{"field": ["furnished"], "value": True, "importance": "must"}]
    }
    app.state.language_model = model
    renter = make_searching_renter(client, mailer, clock)

    response = client.post("/v1/assistant/query", headers=bearer(renter), json={"message": "hi"})

    assert response.status_code == 200
    assert response.json()["understood"]["preferences"] == []


def test_deleting_an_account_deletes_its_questions_to_the_assistant(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    from app.models import AssistantQuery

    renter = make_searching_renter(client, mailer, clock)
    client.post("/v1/assistant/query", headers=bearer(renter), json={"message": "my secret plans"})

    client.delete("/v1/me", headers=bearer(renter))

    assert db.scalars(select(AssistantQuery)).all() == []


# --- Photo checks -------------------------------------------------------------------------


def stored(app: FastAPI, owner_id, data: bytes) -> str:
    key = f"listings/{owner_id}/{uuid.uuid4().hex}.jpg"
    app.state.storage.store.put(key, "image/jpeg", data)
    return key


def with_photo(db, clock, owner, key) -> Listing:
    return put_listing(db, clock, owner, photos=[ListingPhoto(key=key, position=0)])


def run(app: FastAPI, clock: Clock):
    return housekeeping.run_once(app.state.engine, app.state.storage, app.state.push, clock.now)


def test_unreadable_photos_dont_hold_up_the_rest(
    app: FastAPI, db: Session, clock: Clock, monkeypatch
) -> None:
    monkeypatch.setattr(housekeeping, "PHOTOS_PER_RUN", 2)
    owner = make_lister(db)
    for _ in range(2):
        with_photo(db, clock, owner, f"listings/{owner.id}/{uuid.uuid4().hex}.jpg")  # no file
    readable = with_photo(db, clock, owner, stored(app, owner.id, b"real"))

    # Two a run: whichever two come first, the readable one is done by the
    # second run, because the unreadable ones wait a day once tried.
    checked = run(app, clock).photos_checked + run(app, clock).photos_checked
    assert checked == 1
    db.expire_all()
    assert db.scalar(
        select(ListingPhoto.content_hash).where(ListingPhoto.listing_id == readable.id)
    )


def test_every_copy_of_a_photo_is_flagged_and_reports_name_no_one_elses_email(
    app: FastAPI, db: Session, clock: Clock
) -> None:
    original_owner, copier = make_lister(db), make_lister(db)
    with_photo(db, clock, original_owner, stored(app, original_owner.id, b"room"))
    first = with_photo(db, clock, copier, stored(app, copier.id, b"room"))
    second = with_photo(db, clock, copier, stored(app, copier.id, b"room"))

    flagged = set(run(app, clock).flagged)

    assert {first.id, second.id} <= flagged
    for flag in db.scalars(select(Report)):
        assert "@" not in flag.excerpt


def test_seed_listings_sharing_sample_pictures_are_not_flagged(
    app: FastAPI, db: Session, clock: Clock
) -> None:
    seeds = [make_lister(db) for _ in range(2)]
    for seed in seeds:
        db.execute(update(User).where(User.id == seed.id).values(email=f"seed-{seed.id}@uw.edu"))
    db.commit()
    for seed in seeds:
        with_photo(db, clock, seed, stored(app, seed.id, b"sample"))

    assert run(app, clock).flagged == []


# --- Live connection --------------------------------------------------------------------


def test_the_live_connection_still_says_ready_for_an_active_account(
    client: TestClient, mailer: RecordingMailer
) -> None:
    alice = sign_in(client, mailer, "alice@uw.edu")
    with live(client, alice) as ws:
        assert receive(ws) == {"type": "ready"}
