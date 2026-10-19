import uuid
from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict

from app.schemas.chat import Checklist, Filled, MessageOut
from app.schemas.common import UtcDateTime
from app.schemas.listings import ListingOut

Action = Literal["like", "pass"]
Side = Literal["renter", "lister"]


class SwipeIn(BaseModel):
    """A like or pass.

    A renter swiping on a listing sends `listing_id` only. A lister swiping on
    someone who liked their listing also sends that renter's `renter_id`.
    `swipe_id` is an id the app makes up, so a swipe sent twice (a retry after
    a lost answer, or a queue sent again after being offline) counts once.
    """

    model_config = ConfigDict(extra="forbid")

    listing_id: uuid.UUID
    renter_id: uuid.UUID | None = None
    action: Action
    swipe_id: uuid.UUID | None = None


class UndoIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # The `swipe_id` the app sent, or the `id` the server returned.
    swipe_id: uuid.UUID


class SwipeOut(BaseModel):
    id: uuid.UUID
    # The app's own id for this swipe, when it sent one.
    swipe_id: uuid.UUID | None
    side: Side
    action: Action
    listing_id: uuid.UUID
    renter_id: uuid.UUID
    created_at: UtcDateTime


class PersonOut(BaseModel):
    """What one side of a match sees about the other."""

    id: uuid.UUID
    first_name: str | None
    photo_url: str | None
    school_name: str
    verified: bool
    # Sublets this person finished through Sublette (both sides confirmed "Filled").
    completed_sublets: int


class MatchOut(BaseModel):
    id: uuid.UUID
    # The caller's side of this match.
    role: Side
    listing: ListingOut
    renter: PersonOut
    lister: PersonOut
    created_at: UtcDateTime
    checklist: Checklist
    filled: Filled
    # Messages from the other side the caller hasn't opened yet.
    unread_count: int
    last_message: MessageOut | None


class SwipeResult(BaseModel):
    swipe: SwipeOut
    # The match this swipe made, or the one it already made if sent again.
    match: MatchOut | None
    # False when this exact swipe had already been recorded.
    created: bool


class MatchPage(BaseModel):
    """Latest message (or the match itself, before any message) first."""

    items: list[MatchOut]


class SavedPage(BaseModel):
    """Live saved listings, most recently saved first."""

    items: list[ListingOut]


class RenterCard(BaseModel):
    """What a lister sees about a renter who liked their listing. Never the pin."""

    id: uuid.UUID
    first_name: str | None
    photo_url: str | None
    year: str | None
    program: str | None
    bio: str | None
    school_name: str
    verified: bool


class InterestedRenter(BaseModel):
    renter: RenterCard
    # The dates the renter wants.
    start_date: date
    end_date: date
    liked_at: UtcDateTime
    # How the renter meets the lister's filters, such as "No pets".
    fits: list[str]


class InterestedRenterPage(BaseModel):
    """Newest like first."""

    items: list[InterestedRenter]
