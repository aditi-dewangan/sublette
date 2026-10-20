"""The assistant: a renter describes what they want in plain words and gets a
short list with reasons. Three steps (build plan, phase 10):

1. Understand: the message becomes changes to the renter profile's fields.
2. Retrieve: the normal matching engine finds up to 20 eligible listings
   with those changes applied. The model plays no part in eligibility.
3. Rank and explain: the model orders them and says why, in a sentence or
   two each. Any id it returns that wasn't sent is thrown away, so it can
   never add a listing, a price or a fact.

The model sees listing attributes and the public location only: never an
exact address, a name, an email or a chat message. Without a model, or when
it fails, Sublette's own rules (services/understand.py) and the matching
score do both steps, and the answer says so (`generated_by: "sublette"`).
"""

import json
import logging
import re
import uuid
from dataclasses import dataclass, replace
from datetime import date

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AssistantQuery, Listing, Swipe, User
from app.schemas.assistant import AssistantAnswer, AssistantItem, PreferenceChanges
from app.schemas.deck import DeckItem
from app.services.deck import candidates
from app.services.language_model import LanguageModel, ModelUnavailable
from app.services.listings import listing_out
from app.services.matching import (
    METERS_PER_MILE,
    Renter,
    _frozen,
    distance_from_pin,
    failures,
    reasons,
    score,
    score_band,
    summary,
)
from app.services.preferences import preference_problems
from app.services.storage import PhotoStorage
from app.services.understand import understand as understand_by_rules

logger = logging.getLogger("sublette.assistant")

LABEL = "Suggestions are generated automatically and drawn only from listings on Sublette."
RETRIEVE = 20
SHOW = 10
WHY_LENGTH = 300

UNDERSTAND_PROMPT = """You turn a college student's request for a sublet into changes to their
search. Today is {today}. Answer with one JSON object and nothing else, with only the keys
the request sets:
  "start_date", "end_date": "YYYY-MM-DD" (the next such dates from today; a season means
     summer Jun 1-Aug 31, fall Sep 1-Dec 15, spring Jan 15-May 15; a month means all of it)
  "max_rent_cents": the most they'll pay per month, in cents
  "radius_m": how far from their pin, in meters (walking distance is 1600)
  "preferences": a list of {{"field", "value", "importance"}}, importance "must", or "nice" when
     they say ideally, prefer, would be nice, bonus. Fields and values:
     space_type: a list of "entire_unit", "private_room", "shared_room"
     private_bathroom, furnished, laundry, parking, pet_free, smoke_free: true
     housemate_count: the most housemates they'd live with, 0 to 10
     housemate_gender: "women" or "men"
Leave out anything the request doesn't mention. Never invent a value."""

RANK_PROMPT = """You help a college student choose a sublet. You get their request and up to 20
listings that already fit their search. Pick the best ones for what they asked, best first,
and say why each fits in one or two short sentences, using only the facts given.
Answer with one JSON object and nothing else: {"ranked": [{"id": "...", "why": "..."}]}.
Use only ids from the list. Never mention a price, place or fact that isn't in the listing."""


@dataclass
class Outcome:
    answer: AssistantAnswer
    fell_back: bool
    problem: str | None


def _json_object(text: str) -> dict:
    """The JSON object in a model's answer, even with words around it."""
    found = re.search(r"\{.*\}", text, re.DOTALL)
    if not found:
        raise ModelUnavailable("no JSON in the answer")
    try:
        value = json.loads(found.group(0))
    except ValueError as error:
        raise ModelUnavailable("JSON that doesn't parse") from error
    if not isinstance(value, dict):
        raise ModelUnavailable("not a JSON object")
    return value


def understand_with_model(model: LanguageModel, message: str, today: date) -> PreferenceChanges:
    data = _json_object(model.complete(UNDERSTAND_PROMPT.format(today=today), message))
    # A preference the profile can't hold is dropped, not trusted.
    raw = data.get("preferences") or []
    if not isinstance(raw, list):
        raw = []
    kept = []
    for item in raw:
        # A field that isn't even a string (["furnished"]) is garbage too.
        if (
            isinstance(item, dict)
            and isinstance(item.get("field"), str)
            and isinstance(item.get("importance"), str)
            and not preference_problems([item])
        ):
            kept.append(item)
    data["preferences"] = kept
    try:
        changes = PreferenceChanges.model_validate(data)
    except ValidationError as error:
        raise ModelUnavailable("values the profile can't hold") from error
    if changes.start_date and changes.end_date and changes.end_date <= changes.start_date:
        raise ModelUnavailable("an end date before the start")
    return changes


def apply(renter: Renter, changes: PreferenceChanges) -> Renter:
    """The renter's search with the changes in it. Nothing is saved."""
    preferences = {
        field: (field, value, importance) for field, value, importance in renter.preferences
    }
    for item in changes.preferences:
        preferences[item.field] = (item.field, _frozen(item.value), item.importance)
    start = changes.start_date or renter.start_date
    end = changes.end_date or renter.end_date
    if end <= start:
        start, end = renter.start_date, renter.end_date
    return replace(
        renter,
        start_date=start,
        end_date=end,
        max_rent_cents=changes.max_rent_cents or renter.max_rent_cents,
        radius_m=changes.radius_m or renter.radius_m,
        preferences=tuple(preferences.values()),
    )


def retrieve(session: Session, renter: Renter, today: date) -> list[Listing]:
    """Up to 20 eligible listings, best score first: the matching engine alone.
    Liked and saved ones may come back; ones the renter passed on don't."""
    passed = set(
        session.scalars(
            select(Swipe.listing_id).where(
                Swipe.side == "renter", Swipe.renter_id == renter.user_id, Swipe.action == "pass"
            )
        )
    )
    eligible = [
        listing
        for listing in candidates(session, renter, today, include_seen=True)
        if listing.id not in passed and not failures(renter, listing, listing.owner.school_id)
    ]
    eligible.sort(key=lambda listing: (-score(renter, listing), str(listing.id)))
    return eligible[:RETRIEVE]


def model_view(renter: Renter, listing: Listing) -> dict:
    """What the model may know about a listing: attributes and the public
    point. No address, exact point, lister, photos or free text."""
    return {
        "id": str(listing.id),
        "rent_per_month_usd": round(listing.rent_cents / 100) if listing.rent_cents else None,
        "deposit_usd": round(listing.deposit_cents / 100),
        "utilities_included": listing.utilities_included,
        "start_date": str(listing.start_date),
        "end_date": str(listing.end_date),
        "minimum_stay_days": listing.min_stay_days,
        "space_type": listing.space_type,
        "bedrooms": listing.bedrooms,
        "bathroom": listing.bathroom,
        "furnished": listing.furnished,
        "in_unit_laundry": listing.laundry,
        "parking": listing.parking,
        "housemates_staying": listing.housemates_staying,
        "housemates_are": listing.household_gender,
        "pets_allowed": listing.pets_allowed,
        "smoking_allowed": listing.smoking_allowed,
        "public_latitude": round(listing.public_latitude, 4),
        "public_longitude": round(listing.public_longitude, 4),
    }


def rank_with_model(
    model: LanguageModel, message: str, renter: Renter, listings: list[Listing]
) -> list[tuple[Listing, str]]:
    by_id = {str(listing.id): listing for listing in listings}
    request = json.dumps(
        {"request": message, "listings": [model_view(renter, listing) for listing in listings]}
    )
    ranked = _json_object(model.complete(RANK_PROMPT, request)).get("ranked")
    if not isinstance(ranked, list):
        raise ModelUnavailable("no ranked list")
    chosen: list[tuple[Listing, str]] = []
    for entry in ranked:
        if not isinstance(entry, dict):
            continue
        listing = by_id.pop(str(entry.get("id")), None)
        why = entry.get("why")
        # An id that wasn't sent (made up, or repeated) is thrown away here.
        if listing is None or not isinstance(why, str) or not why.strip():
            continue
        chosen.append((listing, why.strip()[:WHY_LENGTH]))
        if len(chosen) == SHOW:
            break
    if not chosen and listings:
        raise ModelUnavailable("no usable picks")
    return chosen


def rank_by_score(renter: Renter, listings: list[Listing]) -> list[tuple[Listing, str]]:
    return [(listing, summary(renter, listing)) for listing in listings[:SHOW]]


def describe(changes: PreferenceChanges) -> str:
    """The understood changes in one line, such as "Private room · under $1,200"."""
    names = {
        "entire_unit": "whole place",
        "private_room": "private room",
        "shared_room": "shared room",
        "private_bathroom": "private bathroom",
        "furnished": "furnished",
        "laundry": "in-unit laundry",
        "parking": "parking",
        "pet_free": "no pets",
        "smoke_free": "no smoking",
    }
    parts = []
    for item in changes.preferences:
        if item.field == "space_type":
            text = " or ".join(names[value] for value in item.value)
        elif item.field == "housemate_count":
            text = "no housemates" if item.value == 0 else f"at most {item.value} housemates"
        elif item.field == "housemate_gender":
            text = f"housemates who are {item.value}"
        else:
            text = names[item.field]
        parts.append(text if item.importance == "must" else f"{text} if possible")
    if changes.max_rent_cents:
        parts.append(f"under ${round(changes.max_rent_cents / 100):,}")
    if changes.start_date and changes.end_date:
        parts.append(
            f"{changes.start_date:%b} {changes.start_date.day} to "
            f"{changes.end_date:%b} {changes.end_date.day}"
        )
    if changes.radius_m:
        parts.append(f"within {changes.radius_m / METERS_PER_MILE:.1f} miles")
    if not parts:
        return "Your current search"
    text = " · ".join(parts)
    return text[0].upper() + text[1:]


def answer(
    session: Session,
    viewer: User,
    renter: Renter,
    message: str,
    model: LanguageModel | None,
    storage: PhotoStorage,
    today: date,
) -> Outcome:
    fell_back, problem = False, None
    changes = understand_by_rules(message, today)
    if model is not None:
        try:
            changes = understand_with_model(model, message, today)
        except ModelUnavailable as error:
            fell_back, problem = True, f"understand: {error}"
            logger.warning("The assistant's model failed to understand (%s); using rules", error)

    searched = apply(renter, changes)
    listings = retrieve(session, searched, today)

    picks = rank_by_score(searched, listings)
    generated_by = "sublette"
    if model is not None and listings:
        try:
            picks = rank_with_model(model, message, searched, listings)
            generated_by = "ai"
        except ModelUnavailable as error:
            fell_back, problem = True, (problem or "") + f" rank: {error}"
            logger.warning("The assistant's model failed to rank (%s); using scores", error)

    items = [
        AssistantItem(
            item=DeckItem(
                listing=listing_out(listing, viewer, storage),
                score=score(searched, listing),
                band=score_band(score(searched, listing)),
                summary=summary(searched, listing),
                reasons=reasons(searched, listing),
                distance_m=round(distance_from_pin(searched, listing)),
            ),
            why=why,
        )
        for listing, why in picks
    ]
    return Outcome(
        answer=AssistantAnswer(
            understood=changes,
            summary=describe(changes),
            items=items,
            generated_by=generated_by,
            label=LABEL,
        ),
        fell_back=fell_back,
        problem=problem.strip()[:200] if problem else None,
    )


def log(session: Session, user: User, message: str, outcome: Outcome, backend: str, now) -> None:
    session.add(
        AssistantQuery(
            id=uuid.uuid4(),
            user_id=user.id,
            message=message,
            understood=outcome.answer.understood.model_dump(mode="json"),
            listing_ids=[str(entry.item.listing.id) for entry in outcome.answer.items],
            backend=backend,
            fell_back=outcome.fell_back,
            problem=outcome.problem,
            created_at=now,
        )
    )
