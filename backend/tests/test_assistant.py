"""The assistant (phase 10): understanding, retrieval, ranking, privacy,
fallbacks, the off switch, and the evaluation set."""

import io
import json
import uuid
from datetime import date

import httpx2
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.assistant_eval import PASS_MARK, run
from app.config import Settings
from app.models import AssistantQuery
from app.services.language_model import AnthropicModel, ModelUnavailable, OllamaModel
from app.services.understand import understand
from tests.conftest import Clock, RecordingMailer, bearer, settings_with, sign_in
from tests.test_deck import make_searching_renter, put_listing
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, swipe, user_of


class FakeModel:
    """Stands in for a language model. Remembers every prompt; answers from
    a script, or fails."""

    name = "fake"

    def __init__(self) -> None:
        self.prompts: list[tuple[str, str]] = []
        self.understanding: dict | str = {}
        self.ranking: dict | str | None = None
        self.failure: Exception | None = None

    def complete(self, system: str, user: str) -> str:
        self.prompts.append((system, user))
        if self.failure is not None:
            raise self.failure
        is_ranking = system.startswith("You help")
        answer = self.ranking if is_ranking else self.understanding
        if is_ranking and answer is None:
            # By default, pick everything it was sent, in reverse.
            sent = json.loads(user)["listings"]
            answer = {"ranked": [{"id": item["id"], "why": "It fits."} for item in reversed(sent)]}
        return answer if isinstance(answer, str) else json.dumps(answer)


@pytest.fixture
def model(app: FastAPI) -> FakeModel:
    fake = FakeModel()
    app.state.language_model = fake
    return fake


@pytest.fixture
def renter(client: TestClient, mailer: RecordingMailer, clock: Clock) -> dict:
    return make_searching_renter(client, mailer, clock)


@pytest.fixture
def lister(client: TestClient, mailer: RecordingMailer) -> dict:
    who = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(who), json={**COMPLETE_PROFILE, "first_name": "Lee"})
    return who


def ask(client: TestClient, who: dict, message: str):
    return client.post("/v1/assistant/query", headers=bearer(who), json={"message": message})


def ids(answer: dict) -> list[str]:
    return [entry["item"]["listing"]["id"] for entry in answer["items"]]


# --- Done when --------------------------------------------------------------------------


def test_a_made_up_listing_id_from_the_model_never_reaches_the_app(
    client: TestClient, model: FakeModel, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    real = put_listing(db, clock, user_of(db, lister))
    invented = str(uuid.uuid4())
    other_users = put_listing(db, clock, user_of(db, lister), status="draft")
    model.ranking = {
        "ranked": [
            {"id": invented, "why": "A lovely loft downtown for $300."},
            {"id": str(other_users.id), "why": "Not even sent."},
            {"id": str(real.id), "why": "Close to your pin and furnished."},
            {"id": str(real.id), "why": "Twice."},
        ]
    }

    answer = ok(ask(client, renter, "something furnished"))

    assert ids(answer) == [str(real.id)]
    assert answer["items"][0]["why"] == "Close to your pin and furnished."
    assert answer["generated_by"] == "ai"
    assert invented not in json.dumps(answer)


def test_the_evaluation_set_gets_at_least_27_of_30_right() -> None:
    out = io.StringIO()

    right = run(None, out)

    assert right >= PASS_MARK, out.getvalue()


def test_turning_the_setting_off_hides_the_screen(
    client: TestClient, app: FastAPI, renter: dict
) -> None:
    assert ok(client.get("/v1/assistant", headers=bearer(renter)))["enabled"] is True

    settings_with(app, assistant_enabled=False)

    assert ok(client.get("/v1/assistant", headers=bearer(renter)))["enabled"] is False
    refused = ask(client, renter, "anything")
    assert refused.status_code == 403 and refused.json()["code"] == "assistant_off"


# --- What the model may see -------------------------------------------------------------


def test_the_model_sees_listing_attributes_and_the_public_point_only(
    client: TestClient, model: FakeModel, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    put_listing(
        db,
        clock,
        user_of(db, lister),
        address="1 Private Way",
        latitude=47.6612345,
        housemates_note="Call Jordan on 206-555-0100",
    )
    match_listing = put_listing(db, clock, user_of(db, lister))
    swipe(client, renter, match_listing.id)
    made = ok(swipe(client, lister, match_listing.id, renter_id=renter["user"]["id"]))["match"]
    client.post(
        f"/v1/matches/{made['id']}/messages",
        headers=bearer(lister),
        json={"body": "My number is 206-555-0199"},
    )

    ok(ask(client, renter, "a furnished room"))

    sent = json.dumps(model.prompts)
    for secret in (
        "1 Private Way",
        "47.6612345",
        "Jordan",
        "206-555",
        "Lee",
        "lister@uw.edu",
        "renter@uw.edu",
        renter["user"]["id"],
    ):
        assert secret not in sent, secret
    ranked = json.loads(model.prompts[-1][1])["listings"]
    assert {"public_latitude", "rent_per_month_usd", "furnished"} <= set(ranked[0])
    assert not {"address", "latitude", "lister", "housemates_note", "photos"} & set(ranked[0])


# --- The three steps --------------------------------------------------------------------


def test_eligibility_is_the_matching_engines_alone(
    client: TestClient, model: FakeModel, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    fits = put_listing(db, clock, user_of(db, lister), furnished=True)
    unfurnished = put_listing(db, clock, user_of(db, lister), furnished=False)
    too_dear = put_listing(db, clock, user_of(db, lister), furnished=True, rent_cents=500_000)
    model.understanding = {
        "preferences": [{"field": "furnished", "value": True, "importance": "must"}]
    }

    answer = ok(ask(client, renter, "furnished please"))

    assert ids(answer) == [str(fits.id)]
    sent = [item["id"] for item in json.loads(model.prompts[-1][1])["listings"]]
    assert str(unfurnished.id) not in sent and str(too_dear.id) not in sent
    assert answer["understood"]["preferences"] == [
        {"field": "furnished", "value": True, "importance": "must"}
    ]


def test_nothing_is_saved_to_the_profile(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    before = ok(client.get("/v1/me/renter-profile", headers=bearer(renter)))

    ok(ask(client, renter, "furnished, under $500, within 1 mile"))

    assert ok(client.get("/v1/me/renter-profile", headers=bearer(renter))) == before


def test_without_a_model_sublettes_rules_answer(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    furnished = put_listing(db, clock, user_of(db, lister), furnished=True)
    put_listing(db, clock, user_of(db, lister), furnished=False)

    answer = ok(ask(client, renter, "I need a furnished place"))

    assert answer["generated_by"] == "sublette"
    assert ids(answer) == [str(furnished.id)]
    assert answer["summary"] == "Furnished"
    assert answer["items"][0]["why"].startswith("Fits your dates")
    assert answer["label"].startswith("Suggestions are generated automatically")


def test_listings_passed_on_dont_come_back(
    client: TestClient, renter: dict, lister: dict, db: Session, clock: Clock
) -> None:
    passed = put_listing(db, clock, user_of(db, lister))
    liked = put_listing(db, clock, user_of(db, lister))
    swipe(client, renter, passed.id, action="pass")
    swipe(client, renter, liked.id)

    assert ids(ok(ask(client, renter, "anything good"))) == [str(liked.id)]


@pytest.mark.parametrize(
    "failure",
    [
        ModelUnavailable("down"),
        ModelUnavailable("slow"),
    ],
)
def test_a_model_that_fails_falls_back_to_the_rules(
    client: TestClient,
    model: FakeModel,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    failure: Exception,
) -> None:
    listing = put_listing(db, clock, user_of(db, lister), furnished=True)
    model.failure = failure

    answer = ok(ask(client, renter, "furnished"))

    assert answer["generated_by"] == "sublette"
    assert ids(answer) == [str(listing.id)]
    [logged] = db.scalars(select(AssistantQuery)).all()
    assert logged.fell_back is True and logged.backend == "fake"


@pytest.mark.parametrize(
    "garbage",
    [
        "Sure! Here are some ideas.",
        "{not json",
        "[1, 2, 3]",
        {"max_rent_cents": "cheap"},
        {"start_date": "2027-08-01", "end_date": "2027-06-01"},
    ],
)
def test_a_model_that_answers_garbage_falls_back(
    client: TestClient,
    model: FakeModel,
    renter: dict,
    lister: dict,
    db: Session,
    clock: Clock,
    garbage,
) -> None:
    put_listing(db, clock, user_of(db, lister))
    model.understanding = garbage
    model.ranking = garbage if isinstance(garbage, str) else {"ranked": "everything"}

    answer = ok(ask(client, renter, "under $1,500"))

    assert answer["generated_by"] == "sublette"
    assert answer["understood"]["max_rent_cents"] == 150_000, "the rules understood it instead"


def test_a_preference_the_profile_cant_hold_is_dropped(
    client: TestClient, model: FakeModel, renter: dict
) -> None:
    model.understanding = {
        "preferences": [
            {"field": "hot_tub", "value": True, "importance": "must"},
            {"field": "furnished", "value": "yes please", "importance": "must"},
            {"field": "laundry", "value": True, "importance": "nice"},
        ]
    }

    answer = ok(ask(client, renter, "laundry would be nice"))

    assert answer["understood"]["preferences"] == [
        {"field": "laundry", "value": True, "importance": "nice"}
    ]


# --- Rules around it --------------------------------------------------------------------


def test_queries_are_logged_for_review_and_shown_on_the_admin_page(
    client: TestClient, app: FastAPI, admin: dict, renter: dict, db: Session
) -> None:
    ok(ask(client, renter, "a <b>furnished</b> room"))

    [logged] = db.scalars(select(AssistantQuery)).all()
    assert logged.message == "a <b>furnished</b> room"
    assert logged.backend == "rules"
    page = client.get("/admin/assistant", headers=admin).text
    assert "a &lt;b&gt;furnished&lt;/b&gt; room" in page


def test_the_assistant_is_rate_limited(client: TestClient, app: FastAPI, renter: dict) -> None:
    settings_with(app, assistant_queries_per_hour=1)

    assert ask(client, renter, "one").status_code == 200
    assert ask(client, renter, "two").status_code == 429


def test_the_assistant_needs_a_search_first(client: TestClient, aditi: dict) -> None:
    assert ask(client, aditi, "anything").status_code == 409


def test_a_message_must_have_words(client: TestClient, renter: dict) -> None:
    assert ask(client, renter, "   ").status_code == 422
    assert ask(client, renter, "x" * 501).status_code == 422


# --- The rules themselves ---------------------------------------------------------------


def test_dates_roll_to_the_next_year_once_passed() -> None:
    changes = understand("a place for the summer", date(2027, 9, 10))

    assert (changes.start_date, changes.end_date) == (date(2028, 6, 1), date(2028, 8, 31))


def test_a_range_across_new_year() -> None:
    changes = understand("Nov 15 to Feb 1", date(2027, 1, 4))

    assert (changes.start_date, changes.end_date) == (date(2027, 11, 15), date(2028, 2, 1))


def test_an_en_dash_typed_on_a_phone_works() -> None:
    changes = understand("June 1 \u2013 July 15", date(2027, 1, 4))

    assert (changes.start_date, changes.end_date) == (date(2027, 6, 1), date(2027, 7, 15))


# --- The model clients ------------------------------------------------------------------


def model_settings(**changes) -> Settings:
    return Settings(env="test", assistant_backend="anthropic", anthropic_api_key="k", **changes)


def client_answering(status: int, body, seen: list | None = None):
    def handler(request: httpx2.Request) -> httpx2.Response:
        if seen is not None:
            seen.append(request)
        if isinstance(body, Exception):
            raise body
        content = body if isinstance(body, bytes) else json.dumps(body).encode()
        return httpx2.Response(status, content=content)

    return httpx2.Client(transport=httpx2.MockTransport(handler))


def test_anthropic_is_asked_the_documented_way() -> None:
    seen: list = []
    answer = {"content": [{"type": "text", "text": '{"ranked": []}'}]}
    model = AnthropicModel(model_settings(), client_answering(200, answer, seen))

    assert model.complete("system", "user") == '{"ranked": []}'
    [request] = seen
    assert request.headers["x-api-key"] == "k"
    assert request.headers["anthropic-version"] == "2023-06-01"
    body = json.loads(request.content)
    assert body["model"] == "claude-haiku-5-5"
    assert body["system"] == "system"


def test_ollama_is_asked_for_json() -> None:
    seen: list = []
    model = OllamaModel(
        model_settings(), client_answering(200, {"message": {"content": "{}"}}, seen)
    )

    assert model.complete("s", "u") == "{}"
    body = json.loads(seen[0].content)
    assert body["format"] == "json" and body["stream"] is False


@pytest.mark.parametrize(
    ("status", "body"),
    [
        (500, {"error": "overloaded"}),
        (401, {"error": "bad key"}),
        (200, b"<html>gateway</html>"),
        (200, {"content": "not a list"}),
        (200, httpx2.ConnectError("refused")),
        (200, httpx2.ReadTimeout("slow")),
    ],
)
def test_model_clients_turn_every_failure_into_unavailable(status: int, body) -> None:
    for make in (AnthropicModel, OllamaModel):
        model = make(model_settings(), client_answering(status, body))
        with pytest.raises(ModelUnavailable):
            model.complete("s", "u")


def test_anthropic_needs_a_key() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_ANTHROPIC_API_KEY"):
        Settings(env="test", assistant_backend="anthropic")
