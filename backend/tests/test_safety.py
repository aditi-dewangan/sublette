"""Reports, blocks, scam flags, rate limits, suspension, the admin page and terms."""

import base64
import re
import uuid

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session
from starlette.websockets import WebSocketDisconnect

from app.config import Settings
from app.models import Block, Listing, Report, User
from app.services.safety import scam_reasons
from tests.conftest import Clock, RecordingMailer, admin_post, bearer, settings_with, sign_in
from tests.test_chat import (
    WIDE,
    RecordingPush,
    device,
    history,
    live,
    pushes,
    receive,
    send,
)
from tests.test_deck import deck, ids, make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import interested, ok, swipe, user_of


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


@pytest.fixture
def listing(db: Session, clock: Clock, lister: dict) -> Listing:
    return put_listing(db, clock, user_of(db, lister))


@pytest.fixture
def match(client: TestClient, renter: dict, lister: dict, listing: Listing) -> dict:
    ok(swipe(client, renter, listing.id))
    return ok(swipe(client, lister, listing.id, renter_id=renter["user"]["id"]))["match"]


def report(client: TestClient, who: dict, target: str, target_id, reason="scam", **extra):
    return client.post(
        "/v1/reports",
        headers=bearer(who),
        json={"target": target, "id": str(target_id), "reason": reason, **extra},
    )


def block(client: TestClient, who: dict, **body):
    response = client.post(
        "/v1/blocks", headers=bearer(who), json={key: str(value) for key, value in body.items()}
    )
    assert response.status_code == 204, response.text


def sent(response) -> dict:
    assert response.status_code == 201, response.text
    return response.json()


def matches(client: TestClient, who: dict) -> list[dict]:
    return ok(client.get("/v1/matches", headers=bearer(who)))["items"]


# --- Reports ---------------------------------------------------------------------------


def test_a_report_made_in_the_app_appears_in_the_admin_queue(
    client: TestClient, app: FastAPI, admin: dict, renter: dict, listing: Listing
) -> None:
    response = report(client, renter, "listing", listing.id, details="Asked for a deposit by wire")

    assert response.status_code == 201, response.text
    assert response.json()["status"] == "open"
    queue = client.get("/admin", headers=admin)
    assert queue.status_code == 200
    assert "Asked for a deposit by wire" in queue.text
    assert "renter@uw.edu" in queue.text and "lister@uw.edu" in queue.text
    assert f"/admin/listings/{listing.id}" in queue.text


def test_reporting_the_same_thing_twice_files_one_report(
    client: TestClient, renter: dict, listing: Listing, db: Session
) -> None:
    first = report(client, renter, "listing", listing.id)
    again = report(client, renter, "listing", listing.id, reason="fake")

    assert again.status_code == 200
    assert again.json()["id"] == first.json()["id"]
    assert len(db.scalars(select(Report)).all()) == 1


def test_every_profile_listing_and_message_can_be_reported(
    client: TestClient, renter: dict, lister: dict, listing: Listing, match: dict, db: Session
) -> None:
    message = sent(send(client, lister, match["id"], "Hi there"))

    for target, target_id in (
        ("user", lister["user"]["id"]),
        ("listing", listing.id),
        ("message", message["id"]),
    ):
        response = report(client, renter, target, target_id, reason="harassment")
        assert response.status_code == 201, (target, response.text)

    rows = {row.target: row for row in db.scalars(select(Report))}
    assert {row.subject_id for row in rows.values()} == {uuid.UUID(lister["user"]["id"])}
    assert rows["message"].excerpt == "Hi there"
    assert rows["message"].listing_id == listing.id


def test_only_the_two_in_a_chat_can_report_its_messages(
    client: TestClient, mailer: RecordingMailer, renter: dict, lister: dict, match: dict
) -> None:
    message = sent(send(client, lister, match["id"], "Hi there"))
    stranger = sign_in(client, mailer, "stranger@uw.edu")

    assert report(client, stranger, "message", message["id"]).status_code == 404
    mine = report(client, lister, "message", message["id"])
    assert mine.json()["code"] == "cant_report_yourself"


def test_reports_on_nothing_or_on_yourself_are_refused(
    client: TestClient, renter: dict, db: Session, clock: Clock
) -> None:
    draft = put_listing(db, clock, user_of(db, renter), status="draft")

    assert report(client, renter, "user", uuid.uuid4()).status_code == 404
    assert report(client, renter, "listing", draft.id).status_code == 404
    assert report(client, renter, "user", renter["user"]["id"]).status_code == 422
    bad = report(client, renter, "user", uuid.uuid4(), reason="because")
    assert bad.status_code == 422


def test_reports_are_rate_limited(
    client: TestClient, app: FastAPI, renter: dict, db: Session, clock: Clock, mailer
) -> None:
    settings_with(app, reports_per_day=2)
    people = [sign_in(client, mailer, f"p{n}@uw.edu")["user"]["id"] for n in range(3)]

    assert report(client, renter, "user", people[0]).status_code == 201
    assert report(client, renter, "user", people[1]).status_code == 201
    third = report(client, renter, "user", people[2])

    assert third.status_code == 429
    clock.advance(days=1, seconds=1)
    renter_again = sign_in(client, mailer, "renter@uw.edu")
    assert report(client, renter_again, "user", people[2]).status_code == 201


# --- Blocks ----------------------------------------------------------------------------


def test_a_blocked_pair_cannot_see_or_message_each_other(
    client: TestClient,
    renter: dict,
    lister: dict,
    listing: Listing,
    match: dict,
    db: Session,
    clock: Clock,
) -> None:
    """The renter blocks the lister from a listing card. Everywhere either of
    them looks, the other is gone, and neither can write to the other."""
    owner = user_of(db, lister)
    unseen = put_listing(db, clock, owner)
    saved = put_listing(db, clock, owner)
    client.post(f"/v1/saved/{saved.id}", headers=bearer(renter))
    other_listing = put_listing(db, clock, owner)
    ok(swipe(client, renter, other_listing.id))
    assert str(unseen.id) in ids(deck(client, renter))

    with live(client, renter) as renter_ws, live(client, lister) as lister_ws:
        receive(renter_ws), receive(lister_ws)  # ready
        block(client, renter, listing_id=unseen.id)
        assert receive(renter_ws) == {"type": "match_removed", "match_id": match["id"]}
        assert receive(lister_ws) == {"type": "match_removed", "match_id": match["id"]}

    # The renter's deck, map, saved list and the listings themselves.
    assert deck(client, renter) == []
    pins = ok(client.get("/v1/map/listings", headers=bearer(renter), params={"bbox": WIDE}))
    assert pins["items"] == []
    assert ok(client.get("/v1/saved", headers=bearer(renter)))["items"] == []
    for hidden in (unseen, saved, listing):
        assert client.get(f"/v1/listings/{hidden.id}", headers=bearer(renter)).status_code == 404
        card = client.get(f"/v1/map/listings/{hidden.id}", headers=bearer(renter))
        assert card.status_code == 404
    assert swipe(client, renter, other_listing.id).status_code == 404

    # Matches and the chat, both ways.
    for who in (renter, lister):
        assert matches(client, who) == []
        for response in (
            client.get(f"/v1/matches/{match['id']}", headers=bearer(who)),
            client.get(f"/v1/matches/{match['id']}/messages", headers=bearer(who)),
            send(client, who, match["id"], "hello?"),
        ):
            assert response.status_code == 404
            assert response.json()["code"] == "chat_unavailable"

    # The lister's side: a like from before the block is hidden, and can't match.
    assert interested(client, lister, other_listing.id) == []
    late = swipe(client, lister, other_listing.id, renter_id=renter["user"]["id"])
    assert late.json()["code"] == "renter_has_not_liked"


def test_a_block_by_either_side_hides_both(
    client: TestClient, renter: dict, lister: dict, listing: Listing, match: dict
) -> None:
    block(client, lister, user_id=renter["user"]["id"])

    assert deck(client, renter) == []
    assert matches(client, renter) == [] and matches(client, lister) == []
    assert ok(client.get("/v1/blocks", headers=bearer(renter)))["items"] == []
    blocked = ok(client.get("/v1/blocks", headers=bearer(lister)))["items"]
    assert [person["user_id"] for person in blocked] == [renter["user"]["id"]]


def test_unblocking_brings_the_chat_back(
    client: TestClient, renter: dict, lister: dict, listing: Listing, match: dict
) -> None:
    sent(send(client, renter, match["id"], "Before the block"))
    block(client, renter, user_id=lister["user"]["id"])

    # Only the one who blocked can lift it.
    client.delete(f"/v1/blocks/{renter['user']['id']}", headers=bearer(lister))
    assert matches(client, lister) == []
    response = client.delete(f"/v1/blocks/{lister['user']['id']}", headers=bearer(renter))

    assert response.status_code == 204
    assert [item["id"] for item in matches(client, lister)] == [match["id"]]
    assert [m["body"] for m in history(client, lister, match["id"])["items"]] == [
        "Before the block"
    ]


def test_blocking_twice_is_harmless_and_yourself_is_refused(
    client: TestClient, renter: dict, lister: dict, db: Session
) -> None:
    block(client, renter, user_id=lister["user"]["id"])
    block(client, renter, user_id=lister["user"]["id"])
    yourself = client.post(
        "/v1/blocks", headers=bearer(renter), json={"user_id": renter["user"]["id"]}
    )
    both = client.post(
        "/v1/blocks",
        headers=bearer(renter),
        json={"user_id": lister["user"]["id"], "listing_id": str(uuid.uuid4())},
    )
    nobody = client.post("/v1/blocks", headers=bearer(renter), json={"user_id": str(uuid.uuid4())})

    assert len(db.scalars(select(Block)).all()) == 1
    assert yourself.json()["code"] == "cant_block_yourself"
    assert both.status_code == 422
    assert nobody.status_code == 404


def test_a_blocked_renter_hears_nothing_about_the_listers_new_places(
    client: TestClient, app: FastAPI, push: RecordingPush, renter: dict, lister: dict, db, clock
) -> None:
    from tests.test_chat import draft_for

    client.put(
        "/v1/me/renter-profile",
        headers=bearer(renter),
        json={
            **ok(client.get("/v1/me/renter-profile", headers=bearer(renter))),
            "notify_new_listings": True,
        },
    )
    device(client, renter, "aa" * 32)
    block(client, renter, user_id=lister["user"]["id"])
    draft = draft_for(db, clock, user_of(db, lister))

    ok(
        client.post(
            f"/v1/listings/{draft.id}/status", headers=bearer(lister), json={"status": "active"}
        )
    )

    assert pushes(app, push) == []


# --- Scam flags ------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("Can you Venmo me the deposit today?", ["payment_request"]),
        ("I only take Zelle or a wire transfer", ["payment_request"]),
        ("Send me the deposit and I'll mail the keys", ["payment_request"]),
        ("Pay with gift cards please", ["payment_request"]),
        ("More photos at https://example.com/room", ["outside_link"]),
        ("see www.my-rooms.net", ["outside_link"]),
        ("Text me on sketchy.xyz", ["outside_link"]),
        ("Venmo first, then photos at bit.ly/abc", ["payment_request", "outside_link"]),
        ("Hi! Is the room still free in June?", []),
        ("Email me at sam@uw.edu", []),
        ("The rent is $900 and utilities are about $60", []),
    ],
)
def test_scam_patterns(text: str, expected: list[str]) -> None:
    assert scam_reasons(text) == expected


def test_payment_requests_early_in_a_chat_are_flagged_for_review(
    client: TestClient, lister: dict, renter: dict, match: dict, db: Session
) -> None:
    sent(send(client, lister, match["id"], "Hi! Thanks for the like"))
    sent(send(client, lister, match["id"], "Venmo me $500 to hold it, link: www.holdmyroom.com"))
    sent(send(client, renter, match["id"], "Can I see it first?"))
    # Past the first three messages nothing is flagged.
    sent(send(client, lister, match["id"], "OK, Venmo after the tour then"))

    flags = db.scalars(select(Report).order_by(Report.reason)).all()
    assert [(flag.source, flag.reason) for flag in flags] == [
        ("automatic", "outside_link"),
        ("automatic", "payment_request"),
    ]
    assert {flag.subject_id for flag in flags} == {uuid.UUID(lister["user"]["id"])}
    assert flags[0].excerpt.startswith("Venmo me $500")
    # The message still arrived: flags are for review, not for hiding.
    assert len(history(client, renter, match["id"])["items"]) == 4


# --- Rate limits -----------------------------------------------------------------------


def test_messages_are_rate_limited_but_a_resend_is_not(
    client: TestClient, app: FastAPI, renter: dict, match: dict, clock: Clock
) -> None:
    settings_with(app, messages_per_minute=2)
    first_id = str(uuid.uuid4())
    sent(send(client, renter, match["id"], "one", message_id=first_id))
    sent(send(client, renter, match["id"], "two"))

    third = send(client, renter, match["id"], "three")
    resend = send(client, renter, match["id"], "one", message_id=first_id)

    assert third.status_code == 429
    assert "Retry-After" in third.headers
    assert resend.status_code == 200
    clock.advance(minutes=1, seconds=1)
    assert send(client, renter, match["id"], "three").status_code == 201


def test_swipes_are_rate_limited(
    client: TestClient, app: FastAPI, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    settings_with(app, swipes_per_hour=2)
    owner = user_of(db, lister)
    places = [put_listing(db, clock, owner) for _ in range(3)]

    assert swipe(client, renter, places[0].id).status_code == 200
    assert swipe(client, renter, places[1].id, action="pass").status_code == 200
    assert swipe(client, renter, places[2].id).status_code == 429


def test_listing_creation_is_rate_limited(client: TestClient, app: FastAPI, lister: dict) -> None:
    settings_with(app, listings_per_day=1)

    assert client.post("/v1/listings", headers=bearer(lister), json={}).status_code == 201
    assert client.post("/v1/listings", headers=bearer(lister), json={}).status_code == 429


# --- Suspension ------------------------------------------------------------------------


def test_a_suspension_takes_effect_on_the_next_request(
    client: TestClient,
    app: FastAPI,
    admin: dict,
    push: RecordingPush,
    renter: dict,
    lister: dict,
    listing: Listing,
    match: dict,
    db: Session,
) -> None:
    device(client, lister, "bb" * 32)
    with live(client, lister) as ws:
        receive(ws)
        response = admin_post(
            client,
            app,
            admin,
            f"/admin/users/{lister['user']['id']}/suspend",
            reason="asking renters to pay before a tour",
        )
        assert response.status_code == 303
        # The open connection closes at once.
        with pytest.raises(WebSocketDisconnect) as closed:
            receive(ws)
        assert closed.value.code == 4403

    me = client.get("/v1/me", headers=bearer(lister))
    refresh = client.post("/v1/auth/refresh", json={"refresh_token": lister["refresh_token"]})
    assert me.status_code == 403 and refresh.status_code == 403
    message = me.json()["message"]
    assert "asking renters to pay before a tour" in message
    assert "subletteofficial@gmail.com" in message
    # Their listings leave decks, and pushes to them stop.
    assert deck(client, renter) == []
    sent(send(client, renter, match["id"], "Are you there?"))
    assert pushes(app, push) == []


def test_lifting_a_suspension_lets_them_back_in(
    client: TestClient, app: FastAPI, admin: dict, lister: dict, db: Session
) -> None:
    path = f"/admin/users/{lister['user']['id']}"
    admin_post(client, app, admin, f"{path}/suspend", reason="spam")
    admin_post(client, app, admin, f"{path}/unsuspend")

    assert client.get("/v1/me", headers=bearer(lister)).status_code == 200
    db.expire_all()
    assert user_of(db, lister).suspended_reason is None


# --- The admin page --------------------------------------------------------------------


def test_the_admin_page_is_off_without_a_password(client: TestClient) -> None:
    assert client.get("/admin").status_code == 404


def test_the_admin_page_needs_the_password(client: TestClient, app: FastAPI, admin: dict) -> None:
    wrong = {"Authorization": "Basic " + base64.b64encode(b"admin:guess").decode()}

    nothing = client.get("/admin")
    bad = client.get("/admin", headers=wrong)

    assert nothing.status_code == 401
    assert nothing.headers["WWW-Authenticate"].startswith("Basic")
    assert bad.status_code == 401
    assert client.get("/admin", headers=admin).status_code == 200


def test_wrong_admin_passwords_are_limited(client: TestClient, app: FastAPI, admin: dict) -> None:
    wrong = {"Authorization": "Basic " + base64.b64encode(b"admin:guess").decode()}
    for _ in range(20):
        assert client.get("/admin", headers=wrong).status_code == 401

    assert client.get("/admin", headers=wrong).status_code == 429
    assert client.get("/admin", headers=admin).status_code == 429, "even the right one, for now"


def test_admin_forms_need_their_token(
    client: TestClient, app: FastAPI, admin: dict, lister: dict
) -> None:
    response = client.post(
        f"/admin/users/{lister['user']['id']}/suspend",
        headers=admin,
        data={"token": "forged", "reason": "x"},
    )

    assert response.status_code == 403
    assert client.get("/v1/me", headers=bearer(lister)).status_code == 200


def test_the_admin_page_is_not_part_of_the_api(app: FastAPI) -> None:
    assert not [path for path in app.openapi()["paths"] if path.startswith("/admin")]


def test_a_short_admin_password_is_refused_on_a_hosted_server() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_ADMIN_PASSWORD"):
        Settings(env="staging", secret_key="s" * 40, admin_password="short")


def test_removing_a_listing_takes_it_down_and_tells_the_owner(
    client: TestClient,
    app: FastAPI,
    admin: dict,
    renter: dict,
    lister: dict,
    listing: Listing,
    db: Session,
) -> None:
    report(client, renter, "listing", listing.id)

    response = admin_post(
        client, app, admin, f"/admin/listings/{listing.id}/remove", reason="photos of another place"
    )

    assert response.status_code == 303
    assert deck(client, renter) == []
    mine = ok(client.get(f"/v1/listings/{listing.id}", headers=bearer(lister)))
    assert mine["status"] == "removed"
    assert mine["removed_reason"] == "photos of another place"
    assert client.get(f"/v1/listings/{listing.id}", headers=bearer(renter)).status_code == 404
    for change in (
        client.patch(f"/v1/listings/{listing.id}", headers=bearer(lister), json={"rent_cents": 1}),
        client.post(
            f"/v1/listings/{listing.id}/status", headers=bearer(lister), json={"status": "active"}
        ),
    ):
        assert change.status_code == 409
    db.expire_all()
    assert db.scalar(select(Report.status)) == "actioned"
    assert "Nothing here" in client.get("/admin", headers=admin).text


def test_dismissing_a_report_closes_it(
    client: TestClient, app: FastAPI, admin: dict, renter: dict, listing: Listing, db: Session
) -> None:
    filed = report(client, renter, "listing", listing.id).json()

    admin_post(client, app, admin, f"/admin/reports/{filed['id']}/dismiss")

    db.expire_all()
    assert db.get(Report, uuid.UUID(filed["id"])).status == "dismissed"
    closed = client.get("/admin", headers=admin, params={"status": "closed"})
    assert "dismissed" in closed.text


def test_admin_pages_escape_what_students_write(
    client: TestClient, app: FastAPI, admin: dict, renter: dict, lister: dict, listing: Listing
) -> None:
    report(client, renter, "listing", listing.id, details="<script>alert(1)</script>")
    client.patch("/v1/me", headers=bearer(lister), json={"first_name": "<b>Lee</b>"})

    pages = [
        client.get("/admin", headers=admin).text,
        client.get(f"/admin/users/{lister['user']['id']}", headers=admin).text,
        client.get(f"/admin/listings/{listing.id}", headers=admin).text,
        client.get("/admin/find", headers=admin, params={"q": "<i>"}).text,
    ]

    for text in pages:
        assert "<script>" not in text and "<b>Lee" not in text and "<i>" not in text
    assert "&lt;script&gt;" in pages[0]


def test_finding_a_person_by_email(
    client: TestClient, app: FastAPI, admin: dict, lister: dict
) -> None:
    found = client.get(
        "/admin/find", headers=admin, params={"q": "LISTER@"}, follow_redirects=False
    )

    assert found.status_code == 303
    assert found.headers["location"] == f"/admin/users/{lister['user']['id']}"


# --- Terms -----------------------------------------------------------------------------


def test_accepting_the_terms_is_recorded(
    client: TestClient, aditi: dict, db: Session, clock: Clock
) -> None:
    assert aditi["user"]["terms_accepted"] is False
    version = aditi["user"]["terms_version"]

    old = client.post("/v1/me/terms", headers=bearer(aditi), json={"version": "2001-01-01"})
    accepted = client.post("/v1/me/terms", headers=bearer(aditi), json={"version": version})

    assert old.status_code == 409 and old.json()["code"] == "terms_outdated"
    assert accepted.status_code == 200 and accepted.json()["terms_accepted"] is True
    user = user_of(db, aditi)
    assert user.terms_version == version and user.terms_accepted_at == clock.now


def test_new_terms_ask_everyone_again(client: TestClient, app: FastAPI, aditi: dict) -> None:
    client.post(
        "/v1/me/terms", headers=bearer(aditi), json={"version": aditi["user"]["terms_version"]}
    )
    settings_with(app, terms_version="2027-06-01")

    me = ok(client.get("/v1/me", headers=bearer(aditi)))

    assert me["terms_accepted"] is False and me["terms_version"] == "2027-06-01"


@pytest.mark.parametrize("path", ["/terms", "/privacy"])
def test_the_terms_and_privacy_policy_are_public_pages(client: TestClient, path: str) -> None:
    response = client.get(path)

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "subletteofficial@gmail.com" in response.text
    assert re.search(r"Version \d{4}-\d{2}-\d{2}", response.text)


# --- Deleting an account ---------------------------------------------------------------


def test_deleting_an_account_keeps_reports_it_made_and_drops_reports_about_it(
    client: TestClient, mailer: RecordingMailer, renter: dict, lister: dict, db: Session
) -> None:
    report(client, renter, "user", lister["user"]["id"])
    other = sign_in(client, mailer, "other@uw.edu")
    report(client, other, "user", renter["user"]["id"])
    block(client, renter, user_id=lister["user"]["id"])

    assert client.delete("/v1/me", headers=bearer(renter)).status_code == 204

    rows = db.scalars(select(Report)).all()
    assert [(row.reporter_id, row.subject_id) for row in rows] == [
        (None, uuid.UUID(lister["user"]["id"]))
    ]
    assert db.scalars(select(Block)).all() == []
    assert db.get(User, uuid.UUID(renter["user"]["id"])) is None
