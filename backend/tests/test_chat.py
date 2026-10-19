"""Chat, the checklist, "Filled", live events and push notifications."""

import json
import time
import uuid

import anyio
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session
from starlette.websockets import WebSocketDisconnect

from app.models import DeviceToken, Listing, ListingPhoto, Message, User
from app.services.push import PushNote, PushUnavailable
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_deck import deck, ids, make_searching_renter, put_listing, search
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, swipe, user_of

WIDE = "-123,47,-122,48"


class RecordingPush:
    """Stands in for Apple. Remembers what it was asked to send; can fail."""

    def __init__(self) -> None:
        self.sent: list[tuple[str, PushNote]] = []
        self.failure: Exception | None = None
        self.delay = 0.0
        self.dead_tokens: set[str] = set()

    def send(self, token: str, environment: str, note: PushNote) -> str:
        if self.delay:
            time.sleep(self.delay)
        if self.failure is not None:
            raise self.failure
        if token in self.dead_tokens:
            return "unregistered"
        self.sent.append((token, note))
        return "sent"


@pytest.fixture
def push(app: FastAPI) -> RecordingPush:
    recording = RecordingPush()
    app.state.push.sender = recording
    return recording


def pushes(app: FastAPI, push: RecordingPush) -> list[tuple[str, PushNote]]:
    app.state.push.drain()
    return push.sent


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json=COMPLETE_PROFILE)
    return who


@pytest.fixture
def listing(db: Session, clock: Clock, lister: dict) -> Listing:
    return put_listing(db, clock, user_of(db, lister))


@pytest.fixture
def match(client: TestClient, renter: dict, lister: dict, listing: Listing) -> dict:
    """The renter and lister matched on the listing."""
    ok(swipe(client, renter, listing.id))
    made = ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))["match"]
    assert made is not None
    return made


def draft_for(db: Session, clock: Clock, owner: User, **changes) -> Listing:
    """A finished listing not yet published."""
    photos = [ListingPhoto(key=f"x/{uuid.uuid4().hex}.jpg", position=i) for i in range(4)]
    return put_listing(
        db, clock, owner, status="draft", published_at=None, photos=photos, **changes
    )


def device(client: TestClient, who: dict, token: str) -> None:
    response = client.post(
        "/v1/devices", headers=bearer(who), json={"token": token, "environment": "sandbox"}
    )
    assert response.status_code == 204, response.text


def send(client: TestClient, who: dict, match_id: str, body: str, **extra):
    return client.post(
        f"/v1/matches/{match_id}/messages", headers=bearer(who), json={"body": body, **extra}
    )


def history(client: TestClient, who: dict, match_id: str, **params) -> dict:
    return ok(client.get(f"/v1/matches/{match_id}/messages", headers=bearer(who), params=params))


def my_match(client: TestClient, who: dict, match_id: str) -> dict:
    return ok(client.get(f"/v1/matches/{match_id}", headers=bearer(who)))


def receive(ws, seconds: float = 2.0) -> dict:
    """The next event, or fail after `seconds` instead of waiting forever."""

    async def next_message():
        with anyio.fail_after(seconds):
            return await ws._send_rx.receive()

    message = ws.portal.call(next_message)
    ws._raise_on_close(message)
    return json.loads(message["text"])


def live(client: TestClient, who: dict):
    return client.websocket_connect("/v1/ws", headers=bearer(who))


# --- Who can read and write --------------------------------------------------------


def test_a_third_user_gets_403_on_another_pairs_chat(
    client: TestClient, mailer: RecordingMailer, match: dict
) -> None:
    stranger = sign_in(client, mailer, "stranger@uw.edu")
    path = f"/v1/matches/{match['id']}"
    calls = [
        client.get(path, headers=bearer(stranger)),
        client.get(f"{path}/messages", headers=bearer(stranger)),
        client.post(f"{path}/messages", headers=bearer(stranger), json={"body": "hi"}),
        client.post(f"{path}/read", headers=bearer(stranger)),
        client.patch(f"{path}/checklist", headers=bearer(stranger), json={"tour_done": True}),
        client.post(f"{path}/filled", headers=bearer(stranger)),
    ]

    for response in calls:
        assert response.status_code == 403, response.request.url
        assert response.json()["code"] == "not_your_match"


def test_a_match_that_does_not_exist_also_answers_403(client: TestClient, renter: dict) -> None:
    response = client.get(f"/v1/matches/{uuid.uuid4()}/messages", headers=bearer(renter))

    assert response.status_code == 403


def test_nothing_reaches_a_stranger(
    client: TestClient, mailer: RecordingMailer, renter: dict, lister: dict, match: dict
) -> None:
    ok_send = send(client, renter, match["id"], "Is it still free?")
    stranger = sign_in(client, mailer, "stranger@uw.edu")

    assert ok_send.status_code == 201
    assert ok(client.get("/v1/matches", headers=bearer(stranger)))["items"] == []


# --- Messages ---------------------------------------------------------------------


def test_matched_people_can_talk(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    first = send(client, renter, match["id"], "  Hi! Is the room still free?  ")
    second = send(client, lister, match["id"], "Yes, want to tour Thursday?")

    assert first.status_code == 201 and second.status_code == 201
    assert first.json()["body"] == "Hi! Is the room still free?"
    seen_by_lister = history(client, lister, match["id"])
    assert [m["body"] for m in seen_by_lister["items"]] == [
        "Hi! Is the room still free?",
        "Yes, want to tour Thursday?",
    ]
    assert [m["mine"] for m in seen_by_lister["items"]] == [False, True]
    assert seen_by_lister["has_more"] is False


def test_messages_keep_their_order_within_one_second(
    client: TestClient, renter: dict, match: dict
) -> None:
    # The test clock never moves, so every message has the same time.
    for number in range(12):
        send(client, renter, match["id"], f"message {number}")

    bodies = [m["body"] for m in history(client, renter, match["id"])["items"]]

    assert bodies == [f"message {number}" for number in range(12)]


def test_older_messages_come_in_pages(client: TestClient, renter: dict, match: dict) -> None:
    for number in range(7):
        send(client, renter, match["id"], f"message {number}")

    latest = history(client, renter, match["id"], limit=3)
    older = history(client, renter, match["id"], limit=3, before=latest["items"][0]["id"])
    oldest = history(client, renter, match["id"], limit=3, before=older["items"][0]["id"])

    assert [m["body"][-1] for m in latest["items"]] == ["4", "5", "6"]
    assert latest["has_more"] is True
    assert [m["body"][-1] for m in older["items"]] == ["1", "2", "3"]
    assert [m["body"][-1] for m in oldest["items"]] == ["0"]
    assert oldest["has_more"] is False


def test_a_message_sent_twice_is_stored_once(
    client: TestClient, renter: dict, match: dict, db: Session
) -> None:
    message_id = str(uuid.uuid4())

    first = send(client, renter, match["id"], "hello", message_id=message_id)
    again = send(client, renter, match["id"], "hello", message_id=message_id)

    assert first.status_code == 201
    assert again.status_code == 200
    assert again.json()["id"] == first.json()["id"]
    assert again.json()["message_id"] == message_id
    assert db.scalar(select(func.count()).select_from(Message)) == 1


def test_a_message_id_cannot_be_reused_by_someone_else(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    message_id = str(uuid.uuid4())
    send(client, renter, match["id"], "hello", message_id=message_id)

    response = send(client, lister, match["id"], "hello", message_id=message_id)

    assert response.status_code == 409
    assert response.json()["code"] == "message_id_taken"


@pytest.mark.parametrize("body", ["", "   ", "x" * 2001])
def test_empty_or_huge_messages_are_refused(
    client: TestClient, renter: dict, match: dict, body: str
) -> None:
    response = send(client, renter, match["id"], body)

    assert response.status_code == 422


def test_unread_counts_and_reading(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    send(client, renter, match["id"], "one")
    send(client, renter, match["id"], "two")

    assert my_match(client, lister, match["id"])["unread_count"] == 2
    assert my_match(client, renter, match["id"])["unread_count"] == 0, "your own aren't unread"
    listed = ok(client.get("/v1/matches", headers=bearer(lister)))["items"][0]
    assert listed["unread_count"] == 2
    assert listed["last_message"]["body"] == "two"
    assert listed["last_message"]["mine"] is False

    assert client.post(f"/v1/matches/{match['id']}/read", headers=bearer(lister)).status_code == 204
    assert my_match(client, lister, match["id"])["unread_count"] == 0

    send(client, renter, match["id"], "three")
    assert my_match(client, lister, match["id"])["unread_count"] == 1


def test_the_latest_conversation_comes_first(
    client: TestClient,
    mailer: RecordingMailer,
    clock: Clock,
    db: Session,
    renter: dict,
    lister: dict,
    match: dict,
) -> None:
    newer_listing = put_listing(db, clock, user_of(db, lister), km_north=1)
    ok(swipe(client, renter, newer_listing.id))
    clock.advance(minutes=1)
    newer = ok(swipe(client, lister, newer_listing.id, renter_id=renter["user"]["id"]))["match"]
    order = [m["id"] for m in ok(client.get("/v1/matches", headers=bearer(renter)))["items"]]
    assert order == [newer["id"], match["id"]]

    clock.advance(minutes=1)
    send(client, lister, match["id"], "Still interested?")

    order = [m["id"] for m in ok(client.get("/v1/matches", headers=bearer(renter)))["items"]]
    assert order == [match["id"], newer["id"]]


def test_a_matched_renter_sees_the_exact_address_in_the_chat(
    client: TestClient, renter: dict, match: dict
) -> None:
    shown = my_match(client, renter, match["id"])["listing"]

    assert shown["is_matched"] is True
    assert shown["address"] == "1 Private Way"


# --- Live --------------------------------------------------------------------------


def test_a_message_reaches_the_other_phone_within_a_second(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    with live(client, lister) as lister_phone, live(client, renter) as renter_phone:
        assert receive(lister_phone) == {"type": "ready"}
        assert receive(renter_phone) == {"type": "ready"}

        started = time.monotonic()
        sent = send(client, renter, match["id"], "Are you around Thursday?").json()
        event = receive(lister_phone, seconds=1)
        elapsed = time.monotonic() - started

        echoed = receive(renter_phone)

    assert elapsed < 1
    assert event["type"] == "message"
    assert event["message"]["id"] == sent["id"]
    assert event["message"]["mine"] is False
    assert event["match"]["unread_count"] == 1
    assert event["match"]["last_message"]["body"] == "Are you around Thursday?"
    assert echoed["message"]["mine"] is True, "the sender's other phones see it as theirs"


def test_the_checklist_changes_on_both_phones(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    with live(client, lister) as lister_phone:
        receive(lister_phone)
        changed = client.patch(
            f"/v1/matches/{match['id']}/checklist",
            headers=bearer(renter),
            json={"tour_done": True, "dates_agreed": True},
        )
        event = receive(lister_phone)

    assert changed.status_code == 200
    assert event["type"] == "match"
    assert event["new_match"] is False
    assert event["match"]["checklist"]["tour_done"] is True
    assert event["match"]["checklist"]["dates_agreed"] is True
    assert event["match"]["role"] == "lister"


def test_a_new_match_reaches_the_renters_phone(
    client: TestClient, renter: dict, lister: dict, listing: Listing
) -> None:
    ok(swipe(client, renter, listing.id))
    with live(client, renter) as renter_phone:
        receive(renter_phone)
        ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))
        event = receive(renter_phone)

    assert event["type"] == "match"
    assert event["new_match"] is True
    assert event["match"]["role"] == "renter"
    assert event["match"]["listing"]["address"] == "1 Private Way"


def test_the_socket_needs_a_valid_token(client: TestClient) -> None:
    with (
        pytest.raises(WebSocketDisconnect) as closed,
        client.websocket_connect("/v1/ws", headers={"Authorization": "Bearer nonsense"}) as ws,
    ):
        receive(ws)

    assert closed.value.code == 4401
    assert closed.value.reason == "token_invalid"


def test_the_socket_closes_when_the_token_expires(
    client: TestClient, renter: dict, clock: Clock
) -> None:
    # The access token lasts 15 minutes; leave it one second.
    clock.advance(minutes=14, seconds=59)

    with pytest.raises(WebSocketDisconnect) as closed, live(client, renter) as ws:
        assert receive(ws) == {"type": "ready"}
        receive(ws, seconds=5)

    assert closed.value.code == 4401
    assert closed.value.reason == "token_expired"


def test_a_suspended_account_is_turned_away(client: TestClient, renter: dict, db: Session) -> None:
    user_of(db, renter).status = "suspended"
    db.commit()

    with pytest.raises(WebSocketDisconnect) as closed, live(client, renter) as ws:
        receive(ws)

    assert closed.value.code == 4403


# --- The checklist and "Filled" ------------------------------------------------------


def test_either_side_ticks_and_unticks_the_checklist(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    assert match["checklist"] == {
        "tour_done": False,
        "landlord_consent_confirmed": False,
        "dates_agreed": False,
        "sublease_signed": False,
        "updated_at": None,
    }
    path = f"/v1/matches/{match['id']}/checklist"

    ok(client.patch(path, headers=bearer(renter), json={"tour_done": True}))
    after = ok(
        client.patch(path, headers=bearer(lister), json={"landlord_consent_confirmed": True})
    )
    undone = ok(client.patch(path, headers=bearer(lister), json={"tour_done": False}))

    assert after["checklist"]["tour_done"] is True
    assert after["checklist"]["landlord_consent_confirmed"] is True
    assert after["checklist"]["updated_at"] == "2027-01-04T17:00:00Z"
    assert undone["checklist"]["tour_done"] is False
    assert my_match(client, renter, match["id"])["checklist"]["landlord_consent_confirmed"]


def test_unknown_checklist_steps_are_refused(client: TestClient, renter: dict, match: dict) -> None:
    response = client.patch(
        f"/v1/matches/{match['id']}/checklist", headers=bearer(renter), json={"paid": True}
    )

    assert response.status_code == 422


def test_a_filled_listing_disappears_from_decks_and_the_map(
    client: TestClient,
    mailer: RecordingMailer,
    clock: Clock,
    db: Session,
    lister: dict,
    listing: Listing,
    match: dict,
) -> None:
    other = sign_in(client, mailer, "other@uw.edu")
    client.patch("/v1/me", headers=bearer(other), json={**COMPLETE_PROFILE, "gender": "woman"})
    client.put("/v1/me/renter-profile", headers=bearer(other), json=search(clock))

    def on_map() -> set[str]:
        page = ok(client.get("/v1/map/listings", headers=bearer(other), params={"bbox": WIDE}))
        return {pin["id"] for pin in page["items"]}

    assert str(listing.id) in ids(deck(client, other))
    assert str(listing.id) in on_map()

    filled = ok(client.post(f"/v1/matches/{match['id']}/filled", headers=bearer(lister)))

    assert filled["listing"]["status"] == "filled"
    assert filled["filled"] == {
        "renter_confirmed": False,
        "lister_confirmed": True,
        "completed": False,
    }
    assert str(listing.id) not in ids(deck(client, other))
    assert str(listing.id) not in on_map()
    card = client.get(f"/v1/map/listings/{listing.id}", headers=bearer(other))
    assert card.status_code == 404


def test_both_sides_confirming_makes_a_completed_sublet(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    path = f"/v1/matches/{match['id']}/filled"

    renter_first = ok(client.post(path, headers=bearer(renter)))
    assert renter_first["filled"]["renter_confirmed"] is True
    assert renter_first["listing"]["status"] == "active", "only the lister closes the listing"
    assert ok(client.get("/v1/me", headers=bearer(renter)))["completed_sublets"] == 0

    both = ok(client.post(path, headers=bearer(lister)))
    again = ok(client.post(path, headers=bearer(lister)))

    assert both["filled"]["completed"] is True
    assert again["filled"]["completed"] is True
    for who in (renter, lister):
        assert ok(client.get("/v1/me", headers=bearer(who)))["completed_sublets"] == 1
    assert both["renter"]["completed_sublets"] == 1
    assert both["lister"]["completed_sublets"] == 1


def test_people_can_still_talk_after_filling(
    client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    ok(client.post(f"/v1/matches/{match['id']}/filled", headers=bearer(lister)))

    assert send(client, renter, match["id"], "Thanks! Moving in Monday.").status_code == 201


# --- Push -----------------------------------------------------------------------------


def test_a_message_is_pushed_when_the_recipient_has_no_app_open(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    device(client, lister, "aa" * 32)

    send(client, renter, match["id"], "Is parking included?")

    [(token, note)] = pushes(app, push)
    assert token == "aa" * 32
    assert note.body == "Is parking included?"
    assert note.data == {"kind": "message", "match_id": match["id"], "role": "lister"}


def test_no_push_while_the_app_is_open(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    device(client, lister, "aa" * 32)

    with live(client, lister) as lister_phone:
        receive(lister_phone)
        send(client, renter, match["id"], "Is parking included?")
        receive(lister_phone)

    assert pushes(app, push) == []


def test_a_new_match_is_pushed_to_the_renter(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    listing: Listing,
) -> None:
    device(client, renter, "bb" * 32)
    ok(swipe(client, renter, listing.id))

    made = ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))["match"]
    ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))  # sent again

    [(token, note)] = pushes(app, push)
    assert token == "bb" * 32
    assert note.title == "It's a match!"
    assert note.data == {"kind": "match", "match_id": made["id"], "role": "renter"}


@pytest.mark.parametrize(
    "failure",
    [PushUnavailable("down"), ValueError("garbage from the provider")],
    ids=["down", "garbage"],
)
def test_a_message_is_saved_when_push_fails(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    match: dict,
    failure: Exception,
) -> None:
    device(client, lister, "aa" * 32)
    push.failure = failure

    response = send(client, renter, match["id"], "hello")
    pushes(app, push)

    assert response.status_code == 201
    assert [m["body"] for m in history(client, lister, match["id"])["items"]] == ["hello"]


def test_a_slow_push_does_not_slow_the_message(
    app: FastAPI, push: RecordingPush, client: TestClient, renter: dict, lister: dict, match: dict
) -> None:
    device(client, lister, "aa" * 32)
    push.delay = 2

    started = time.monotonic()
    response = send(client, renter, match["id"], "hello")
    elapsed = time.monotonic() - started

    assert response.status_code == 201
    assert elapsed < 1
    assert len(pushes(app, push)) == 1


def test_a_phone_apple_says_is_gone_is_forgotten(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    renter: dict,
    lister: dict,
    match: dict,
    db: Session,
) -> None:
    device(client, lister, "aa" * 32)
    device(client, lister, "cc" * 32)
    push.dead_tokens = {"aa" * 32}

    send(client, renter, match["id"], "hello")

    assert [token for token, _ in pushes(app, push)] == ["cc" * 32]
    assert db.scalars(select(DeviceToken.token)).all() == ["cc" * 32]


def test_a_phone_moves_to_whoever_signs_in_on_it(
    client: TestClient, renter: dict, lister: dict, db: Session
) -> None:
    device(client, renter, "AA" * 32)
    device(client, lister, "aa" * 32)

    [row] = db.scalars(select(DeviceToken)).all()
    assert row.user_id == uuid.UUID(lister["user"]["id"])
    assert row.token == "aa" * 32


def test_signing_out_stops_pushes_to_that_phone_only(
    client: TestClient, renter: dict, lister: dict, db: Session
) -> None:
    device(client, renter, "aa" * 32)
    device(client, lister, "bb" * 32)

    assert client.delete(f"/v1/devices/{'bb' * 32}", headers=bearer(renter)).status_code == 204
    assert client.delete(f"/v1/devices/{'aa' * 32}", headers=bearer(renter)).status_code == 204

    assert db.scalars(select(DeviceToken.token)).all() == ["bb" * 32]


def test_a_device_token_must_look_like_one(client: TestClient, renter: dict) -> None:
    response = client.post(
        "/v1/devices", headers=bearer(renter), json={"token": "<script>", "environment": "sandbox"}
    )

    assert response.status_code == 422


def test_notify_me_sends_one_push_for_a_new_place_that_fits(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    clock: Clock,
    renter: dict,
    lister: dict,
    db: Session,
    mailer: RecordingMailer,
) -> None:
    device(client, renter, "aa" * 32)
    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json=search(clock, notify_new_listings=True),
    )
    owner = user_of(db, lister)

    def publish(**changes) -> None:
        draft = draft_for(db, clock, owner, **changes)
        response = client.post(
            f"/v1/listings/{draft.id}/status", headers=bearer(lister), json={"status": "active"}
        )
        assert response.status_code == 200, response.text

    publish(rent_cents=500_000)  # over budget: no push
    publish()
    publish()  # fits too, but one a day is enough

    [(token, note)] = pushes(app, push)
    assert token == "aa" * 32
    assert note.title == "A new place fits your search"
    assert note.data["kind"] == "listing"

    clock.advance(days=1, minutes=1)
    lister.update(sign_in(client, mailer, "lister@uw.edu"))  # the old token expired
    publish()
    assert len(pushes(app, push)) == 2


def test_no_new_place_push_without_notify_me(
    app: FastAPI,
    push: RecordingPush,
    client: TestClient,
    clock: Clock,
    renter: dict,
    lister: dict,
    db: Session,
) -> None:
    device(client, renter, "aa" * 32)
    draft = draft_for(db, clock, user_of(db, lister))

    client.post(
        f"/v1/listings/{draft.id}/status", headers=bearer(lister), json={"status": "active"}
    )

    assert pushes(app, push) == []


# --- Accounts ---------------------------------------------------------------------------


def test_deleting_an_account_removes_its_messages_and_phones(
    client: TestClient, renter: dict, lister: dict, match: dict, db: Session
) -> None:
    device(client, renter, "aa" * 32)
    send(client, renter, match["id"], "hello")
    send(client, lister, match["id"], "hi")

    assert client.delete("/v1/me", headers=bearer(renter)).status_code == 204

    db.expire_all()
    assert db.scalar(select(func.count()).select_from(Message)) == 0
    assert db.scalar(select(func.count()).select_from(DeviceToken)) == 0
    assert db.get(User, uuid.UUID(lister["user"]["id"])) is not None
