import uuid
from typing import Literal

from pydantic import BaseModel

from app.schemas.deck import DeckItem

Band = Literal["strong", "partial", "other"]
PinState = Literal["new", "liked", "saved", "matched"]


class MapPin(BaseModel):
    """One listing on the renter's map. Kept small: hundreds come at once."""

    id: uuid.UUID
    # The public point, or the exact one for a listing the renter matched with.
    latitude: float
    longitude: float
    # True only for a matched listing, whose point is the real address.
    exact: bool
    # 0 to 100, and its band: strong 75+, partial 50 to 74, other below.
    score: int
    band: Band
    # new: not swiped yet. liked, saved, matched: as it says.
    state: PinState
    rent_cents: int | None


class MapPage(BaseModel):
    """Pins inside the box. New listings are those the deck would show."""

    items: list[MapPin]
    # True when more than the limit matched and the weakest were left out.
    truncated: bool


class MapCard(BaseModel):
    """What tapping a pin shows: the same card as the deck, and its state."""

    item: DeckItem
    state: PinState
