"""Swipes, matches, undo and saved listings."""

import threading
import uuid
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import Match, Swipe, User
from app.schemas.swipes import SwipeIn
from app.services.swipes import record_swipe
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_deck import PIN, deck, ids, make_searching_renter, put_listing, search
from tests.test_me import COMPLETE_PROFILE


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    """renter@uw.edu: a woman with a complete profile and a search around UW."""
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


def user_of(db: Session, who: dict) -> User:
    return db.get(User, uuid.UUID(who["user"]["id"]))


@pytest.fixture
def listing(db: Session, clock: Clock, lister: dict):
    return put_listing(db, clock, user_of(db, lister))


def swipe(client: TestClient, who: dict, listing_id, action: str = "like", **extra):
    body = {"listing_id": str(listing_id), "action": action}
    body.update({key: str(value) for key, value in extra.items()})
    return client.post("/v1/swipes", headers=bearer(who), json=body)


def ok(response) -> dict:
    assert response.status_code == 200, response.text
    return response.json()


def count(db: Session, model) -> int:
    db.expire_all()
    return db.scalar(select(func.count()).select_from(model))


def interested(client: TestClient, who: dict, listing_id) -> list[dict]:
    return ok(client.get(f"/v1/listings/{listing_id}/deck/renters", headers=bearer(who)))["items"]


# --- From sign-up to a match ------------------------------------------------------


def test_two_accounts_go_from_sign_up_to_a_match(
    client: TestClient, mailer: RecordingMailer, db: Session, clock: Clock
) -> None:
    lister_session = sign_in(client, mailer, "lee@uw.edu")
    client.patch("/v1/me", headers=bearer(lister_session), json=COMPLETE_PROFILE)
    listing = put_listing(db, clock, user_of(db, lister_session))

    renter_session = sign_in(client, mailer, "sam@uw.edu")
    client.patch("/v1/me", headers=bearer(renter_session), json=COMPLETE_PROFILE)
    client.put("/v1/me/renter-profile", headers=bearer(renter_session), json=search(clock))
    assert ids(deck(client, renter_session)) == [str(listing.id)]

    liked = ok(swipe(client, renter_session, listing.id))
    assert liked["match"] is None
    assert deck(client, renter_session) == [], "a swiped listing leaves the deck"

    people = interested(client, lister_session, listing.id)
    assert [item["renter"]["first_name"] for item in people] == ["Aditi"]
    sam = people[0]["renter"]["id"]

    matched = ok(swipe(client, lister_session, listing.id, renter_id=sam))
    assert matched["match"]["role"] == "lister"
    assert matched["match"]["renter"]["id"] == sam

    for who, role in ((renter_session, "renter"), (lister_session, "lister")):
        matches = ok(client.get("/v1/matches", headers=bearer(who)))["items"]
        assert [(item["listing"]["id"], item["role"]) for item in matches] == [
            (str(listing.id), role)
        ]
    assert interested(client, lister_session, listing.id) == []


# --- One like is never a match ----------------------------------------------------


def test_a_renters_like_alone_makes_no_match(
    client: TestClient, renter: dict, listing, db: Session
) -> None:
    body = ok(swipe(client, renter, listing.id))

    assert body["match"] is None
    assert count(db, Match) == 0


def test_a_lister_cannot_like_someone_who_has_not_liked_them(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    response = swipe(client, lister, listing.id, renter_id=renter["user"]["id"])

    assert response.status_code == 409
    assert response.json()["code"] == "renter_has_not_liked"
    assert count(db, Match) == 0
    assert count(db, Swipe) == 0


def test_a_lister_cannot_like_someone_who_passed(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    ok(swipe(client, renter, listing.id, "pass"))

    response = swipe(client, lister, listing.id, renter_id=renter["user"]["id"])

    assert response.json()["code"] == "renter_has_not_liked"
    assert count(db, Match) == 0


def test_a_lister_pass_makes_no_match(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    ok(swipe(client, renter, listing.id))

    body = ok(swipe(client, lister, listing.id, "pass", renter_id=renter["user"]["id"]))

    assert body["match"] is None
    assert count(db, Match) == 0
    assert interested(client, lister, listing.id) == []


# --- Twice, fast, or offline then online --------------------------------------------


def test_the_same_swipe_twice_changes_nothing(
    client: TestClient, renter: dict, listing, db: Session
) -> None:
    first = ok(swipe(client, renter, listing.id))
    second = ok(swipe(client, renter, listing.id))

    assert first["created"] is True and second["created"] is False
    assert second["swipe"]["id"] == first["swipe"]["id"]
    assert count(db, Swipe) == 1


def test_a_resent_swipe_id_returns_the_first_answer(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    """The app queued a swipe offline and sends it again when back online."""
    ok(swipe(client, renter, listing.id))
    swipe_id = uuid.uuid4()
    first = ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"], swipe_id=swipe_id))

    again = ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"], swipe_id=swipe_id))

    assert again["created"] is False
    assert again["match"]["id"] == first["match"]["id"]
    assert count(db, Swipe) == 2
    assert count(db, Match) == 1


def test_the_opposite_swipe_is_refused_until_undone(
    client: TestClient, renter: dict, listing
) -> None:
    ok(swipe(client, renter, listing.id, "pass"))

    response = swipe(client, renter, listing.id, "like")

    assert response.status_code == 409
    assert response.json()["code"] == "already_swiped"
    assert "Undo" in response.json()["message"]


def test_swiping_fast_from_many_threads_makes_one_swipe_and_one_match(
    app, client: TestClient, renter: dict, lister: dict, listing, db: Session, clock: Clock
) -> None:
    """Ten copies of the lister's like arrive at once, each with its own swipe id."""
    ok(swipe(client, renter, listing.id))
    owner = user_of(db, lister)
    renter_id = uuid.UUID(renter["user"]["id"])
    storage = app.state.storage
    results, errors = [], []
    start = threading.Barrier(10)

    def send() -> None:
        with Session(app.state.engine) as session:
            user = session.get(User, owner.id)
            start.wait()
            try:
                body = SwipeIn(
                    listing_id=listing.id, renter_id=renter_id, action="like", swipe_id=uuid.uuid4()
                )
                results.append(
                    record_swipe(session, app.state.settings, user, body, storage, clock.now)
                )
            except Exception as error:
                errors.append(error)

    threads = [threading.Thread(target=send) for _ in range(10)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert errors == []
    assert sum(result.created for result in results) == 1
    assert {result.match.id for result in results} == {results[0].match.id}
    assert count(db, Match) == 1
    assert db.scalar(select(func.count()).select_from(Swipe).where(Swipe.side == "lister")) == 1


# --- Who may swipe on what ------------------------------------------------------------


def test_renters_cannot_like_a_listing_that_does_not_fit(
    client: TestClient, renter: dict, db: Session, clock: Clock, lister: dict
) -> None:
    listing = put_listing(db, clock, user_of(db, lister), gender_preference="men")

    assert swipe(client, renter, listing.id).json()["code"] == "listing_not_eligible"
    assert swipe(client, renter, listing.id, "pass").status_code == 200


def test_renters_cannot_swipe_their_own_or_a_closed_listing(
    client: TestClient, renter: dict, db: Session, clock: Clock, lister: dict
) -> None:
    mine = put_listing(db, clock, user_of(db, renter))
    paused = put_listing(db, clock, user_of(db, lister), status="paused")

    assert swipe(client, renter, mine.id).json()["code"] == "own_listing"
    assert swipe(client, renter, paused.id).status_code == 404
    assert swipe(client, renter, uuid.uuid4()).status_code == 404


def test_swiping_needs_a_search(client: TestClient, mailer: RecordingMailer, listing) -> None:
    who = sign_in(client, mailer, "new@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)

    assert swipe(client, who, listing.id).json()["code"] == "renter_profile_incomplete"


def test_only_the_owner_can_swipe_on_a_listings_renters(
    client: TestClient, renter: dict, listing, mailer: RecordingMailer
) -> None:
    ok(swipe(client, renter, listing.id))
    stranger = sign_in(client, mailer, "stranger@uw.edu")

    response = swipe(client, stranger, listing.id, renter_id=renter["user"]["id"])

    assert response.status_code == 404
    assert (
        client.get(f"/v1/listings/{listing.id}/deck/renters", headers=bearer(stranger)).status_code
        == 404
    )


def test_a_lister_cannot_match_on_a_filled_listing(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    ok(swipe(client, renter, listing.id))
    listing.status = "filled"
    db.commit()

    response = swipe(client, lister, listing.id, renter_id=renter["user"]["id"])

    assert response.json()["code"] == "listing_closed"


def test_a_renter_who_stops_fitting_leaves_the_listers_deck(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    ok(swipe(client, renter, listing.id))
    client.patch("/v1/me", headers=bearer(renter), json={"smokes": True})

    assert interested(client, lister, listing.id) == []
    response = swipe(client, lister, listing.id, renter_id=renter["user"]["id"])
    assert response.json()["code"] == "renter_not_eligible"


# --- The lister's deck ------------------------------------------------------------------


def test_the_listers_deck_says_how_each_renter_fits(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    listing = put_listing(
        db, clock, user_of(db, lister), min_stay_days=60, pets_allowed=False, smoking_allowed=False
    )
    ok(swipe(client, renter, listing.id))

    [item] = interested(client, lister, listing.id)

    assert item["fits"] == [
        "Stays 90 days (you asked for 60+)",
        "Verified University of Washington student",
        "No pets",
        "Doesn't smoke",
    ]
    assert item["renter"]["first_name"] == "Aditi"
    assert item["start_date"] == search(clock)["start_date"]


def test_the_listers_deck_never_shows_the_renters_pin(
    client: TestClient, renter: dict, lister: dict, listing
) -> None:
    ok(swipe(client, renter, listing.id))

    response = client.get(f"/v1/listings/{listing.id}/deck/renters", headers=bearer(lister))

    assert str(PIN["latitude"]) not in response.text
    assert "radius" not in response.text and "pin" not in response.text


# --- Undo -------------------------------------------------------------------------------


def undo(client: TestClient, who: dict, swipe_id):
    return client.post("/v1/swipes/undo", headers=bearer(who), json={"swipe_id": str(swipe_id)})


def test_undo_puts_the_listing_back_in_the_deck(client: TestClient, renter: dict, listing) -> None:
    swipe_id = uuid.uuid4()
    ok(swipe(client, renter, listing.id, "pass", swipe_id=swipe_id))

    body = ok(undo(client, renter, swipe_id))

    assert body["listing_id"] == str(listing.id)
    assert ids(deck(client, renter)) == [str(listing.id)]


def test_only_the_last_swipe_can_be_undone(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    owner = user_of(db, lister)
    first = put_listing(db, clock, owner)
    second = put_listing(db, clock, owner)
    early = ok(swipe(client, renter, first.id, "pass"))["swipe"]["id"]
    ok(swipe(client, renter, second.id, "pass"))

    response = undo(client, renter, early)

    assert response.status_code == 409
    assert response.json()["code"] == "not_last_swipe"


def test_undo_twice_is_harmless(client: TestClient, renter: dict, listing) -> None:
    swipe_id = uuid.uuid4()
    ok(swipe(client, renter, listing.id, swipe_id=swipe_id))
    ok(undo(client, renter, swipe_id))

    again = undo(client, renter, swipe_id)

    assert again.status_code == 404
    assert again.json()["code"] == "nothing_to_undo"


def test_a_swipe_that_made_a_match_cannot_be_undone(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    liked = ok(swipe(client, renter, listing.id))["swipe"]["id"]
    matched = ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))["swipe"]["id"]

    assert undo(client, lister, matched).json()["code"] == "already_matched"
    assert undo(client, renter, liked).json()["code"] == "already_matched"
    assert count(db, Match) == 1


def test_nobody_can_undo_someone_elses_swipe(
    client: TestClient, renter: dict, listing, mailer: RecordingMailer
) -> None:
    liked = ok(swipe(client, renter, listing.id))["swipe"]["id"]
    other = sign_in(client, mailer, "other@uw.edu")

    assert undo(client, other, liked).status_code == 404


# --- Saved -----------------------------------------------------------------------------


def test_saving_takes_a_listing_out_of_the_deck_until_unsaved(
    client: TestClient, renter: dict, listing
) -> None:
    path = f"/v1/saved/{listing.id}"
    assert client.post(path, headers=bearer(renter)).status_code == 204
    assert client.post(path, headers=bearer(renter)).status_code == 204, "saving twice is fine"

    assert deck(client, renter) == []
    saved = ok(client.get("/v1/saved", headers=bearer(renter)))["items"]
    assert [item["id"] for item in saved] == [str(listing.id)]
    assert saved[0]["address"] is None

    assert client.delete(path, headers=bearer(renter)).status_code == 204
    assert client.delete(path, headers=bearer(renter)).status_code == 204
    assert ids(deck(client, renter)) == [str(listing.id)]
    assert ok(client.get("/v1/saved", headers=bearer(renter)))["items"] == []


def test_only_live_listings_can_be_saved(
    client: TestClient, renter: dict, db: Session, clock: Clock, lister: dict
) -> None:
    draft = put_listing(db, clock, user_of(db, lister), status="draft")

    assert client.post(f"/v1/saved/{draft.id}", headers=bearer(renter)).status_code == 404


def test_a_saved_listing_that_closes_leaves_the_saved_list(
    client: TestClient, renter: dict, listing, db: Session
) -> None:
    client.post(f"/v1/saved/{listing.id}", headers=bearer(renter))
    listing.status = "filled"
    db.commit()

    assert ok(client.get("/v1/saved", headers=bearer(renter)))["items"] == []


# --- The renter's empty deck -------------------------------------------------------------


def test_diagnostics_know_the_renter_has_seen_everything(
    client: TestClient, renter: dict, listing
) -> None:
    ok(swipe(client, renter, listing.id, "pass"))

    body = ok(client.get("/v1/deck/diagnostics", headers=bearer(renter)))

    assert body["in_area"] == 0
    assert body["seen"] == 1
    assert body["top_must_have"] is None, "not 'nothing in your area'"


def test_notify_me_is_saved_with_the_search(client: TestClient, renter: dict, clock: Clock) -> None:
    body = ok(
        client.put(
            "/v1/me/renter-profile",
            headers=bearer(renter),
            json={**search(clock), "notify_new_listings": True},
        )
    )

    assert body["notify_new_listings"] is True


# --- Deleting an account ------------------------------------------------------------------


def test_deleting_an_account_removes_its_swipes_and_matches(
    client: TestClient, renter: dict, lister: dict, listing, db: Session
) -> None:
    ok(swipe(client, renter, listing.id))
    ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))
    client.post(f"/v1/saved/{listing.id}", headers=bearer(renter))

    assert client.delete("/v1/me", headers=bearer(renter)).status_code == 204

    assert count(db, Swipe) == 0
    assert count(db, Match) == 0
    assert ok(client.get("/v1/matches", headers=bearer(lister)))["items"] == []


def test_signing_in_is_required(client: TestClient) -> None:
    listing_id = uuid.uuid4()
    assert client.post("/v1/swipes", json={}).status_code == 401
    assert client.post("/v1/swipes/undo", json={}).status_code == 401
    assert client.get("/v1/matches").status_code == 401
    assert client.get("/v1/saved").status_code == 401
    assert client.post(f"/v1/saved/{listing_id}").status_code == 401
    assert client.get(f"/v1/listings/{listing_id}/deck/renters").status_code == 401


def test_listings_that_ended_still_show_in_matches(
    client: TestClient, renter: dict, lister: dict, listing, db: Session, clock: Clock
) -> None:
    ok(swipe(client, renter, listing.id))
    ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))
    listing.end_date = clock.now.date() - timedelta(days=1)
    db.commit()

    assert len(ok(client.get("/v1/matches", headers=bearer(renter)))["items"]) == 1
