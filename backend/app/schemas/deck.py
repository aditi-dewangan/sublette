from typing import Literal

from pydantic import BaseModel

from app.schemas.listings import ListingOut


class DeckItem(BaseModel):
    """One listing in the renter's deck, with how well it fits and why."""

    # As any renter sees it: public point only, never the exact address.
    listing: ListingOut
    # 0 to 100.
    score: int
    # Three or four short sentences, such as "Fits your dates".
    reasons: list[str]
    # From the renter's pin to the listing's public point.
    distance_m: int


class DeckPage(BaseModel):
    """Best fit first; newer listings first when two fit equally."""

    items: list[DeckItem]


class Blocker(BaseModel):
    """Something that keeps listings out of the deck."""

    # A preference name for must-haves, such as `furnished`; for lister filters
    # one of pets, smoking, gender, gender_missing, school, dates, min_stay;
    # `radius` when nothing is in the area at all.
    field: str
    kind: Literal["must_have", "lister_filter", "area"]
    # How many listings in the area this alone or with others keeps out.
    removed: int
    message: str


class DeckDiagnostics(BaseModel):
    # Live listings inside the renter's circle, not counting their own.
    in_area: int
    # Of those, how many the renter may see.
    eligible: int
    # Listings in the circle the renter already swiped on or saved (not in `in_area`).
    seen: int
    # The must-have that keeps out the most listings, or null when none does.
    # When nothing is in the area, this is the radius instead.
    top_must_have: Blocker | None
    # Every reason listings are kept out, most listings first.
    blockers: list[Blocker]
