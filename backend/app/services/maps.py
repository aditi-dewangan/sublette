"""The renter's map: the deck's listings, plus the ones they liked, saved or
matched with, as pins inside the visible box."""

import uuid
from dataclasses import dataclass
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.errors import ApiError
from app.models import Listing, Match, SavedListing, Swipe, User
from app.schemas.deck import DeckItem
from app.schemas.maps import MapCard, MapPin
from app.services.deck import candidates
from app.services.listings import listing_out, not_found
from app.services.matching import (
    Renter,
    distance_from_pin,
    failures,
    reasons,
    score,
    score_band,
    summary,
)
from app.services.safety import blocked_with, is_blocked
from app.services.storage import PhotoStorage

MAX_PINS = 500
# Statuses a liked, saved or matched listing may have and still be on the map.
SHOWN_STATUSES = ("active", "paused")


@dataclass(frozen=True)
class BBox:
    min_lng: float
    min_lat: float
    max_lng: float
    max_lat: float

    def contains(self, latitude: float, longitude: float) -> bool:
        return (
            self.min_lat <= latitude <= self.max_lat and self.min_lng <= longitude <= self.max_lng
        )


def parse_bbox(text: str) -> BBox:
    """`min_lng,min_lat,max_lng,max_lat`, the usual order for map boxes."""
    try:
        values = [float(part) for part in text.split(",")]
    except ValueError:
        values = []
    if len(values) != 4:
        raise _bad_bbox()
    box = BBox(*values)
    if not (-180 <= box.min_lng < box.max_lng <= 180 and -90 <= box.min_lat < box.max_lat <= 90):
        raise _bad_bbox()
    return box


def _bad_bbox() -> ApiError:
    return ApiError(
        422,
        "invalid_bbox",
        "The map area must be min_lng,min_lat,max_lng,max_lat, west before east.",
    )


def _states(session: Session, renter_id: uuid.UUID) -> dict[uuid.UUID, str]:
    """liked, passed, saved and matched listing ids for one renter. Matched wins."""
    states: dict[uuid.UUID, str] = {}
    for listing_id in session.scalars(
        select(SavedListing.listing_id).where(SavedListing.user_id == renter_id)
    ):
        states[listing_id] = "saved"
    for listing_id, action in session.execute(
        select(Swipe.listing_id, Swipe.action).where(
            Swipe.side == "renter", Swipe.renter_id == renter_id
        )
    ):
        states[listing_id] = "liked" if action == "like" else "passed"
    for listing_id in session.scalars(select(Match.listing_id).where(Match.renter_id == renter_id)):
        states[listing_id] = "matched"
    return states


def _pin(renter: Renter, listing: Listing, state: str) -> MapPin:
    value = score(renter, listing)
    matched = state == "matched"
    return MapPin(
        id=listing.id,
        latitude=listing.latitude if matched else listing.public_latitude,
        longitude=listing.longitude if matched else listing.public_longitude,
        exact=matched,
        score=value,
        band=score_band(value),
        state=state,
        rent_cents=listing.rent_cents,
    )


def map_pins(session: Session, renter: Renter, box: BBox, today: date) -> tuple[list[MapPin], bool]:
    """Pins inside `box`:

    * new: exactly the listings the deck would show (eligible, inside the
      renter's circle, not swiped or saved), so map and deck always agree;
    * liked, saved and matched: wherever they are in the box, while still
      live or paused. Passed listings are not shown, as in the deck.
    """
    pins: list[MapPin] = []
    for listing in candidates(session, renter, today):
        if not box.contains(listing.public_latitude, listing.public_longitude):
            continue
        if failures(renter, listing, listing.owner.school_id):
            continue
        pins.append(_pin(renter, listing, "new"))

    states = {key: value for key, value in _states(session, renter.user_id).items()}
    shown = [listing_id for listing_id, state in states.items() if state != "passed"]
    if shown:
        for listing in session.scalars(
            select(Listing).where(
                Listing.id.in_(shown),
                Listing.status.in_(SHOWN_STATUSES),
                Listing.owner_id.not_in(blocked_with(renter.user_id)),
            )
        ).unique():
            pin = _pin(renter, listing, states[listing.id])
            if box.contains(pin.latitude, pin.longitude):
                pins.append(pin)

    pins.sort(key=lambda pin: (pin.state != "matched", -pin.score, str(pin.id)))
    return pins[:MAX_PINS], len(pins) > MAX_PINS


def map_card(
    session: Session, viewer: User, renter: Renter, listing_id: uuid.UUID, storage: PhotoStorage
) -> MapCard:
    """The card for one pin. Only listings the map would show have a card."""
    listing = session.get(Listing, listing_id)
    state = _states(session, renter.user_id).get(listing_id, "new")
    if listing is None or listing.owner_id == viewer.id or state == "passed":
        raise not_found()
    if is_blocked(session, viewer.id, listing.owner_id):
        raise not_found()
    if state == "new":
        if listing.status != "active" or failures(renter, listing, listing.owner.school_id):
            raise not_found()
    elif listing.status not in SHOWN_STATUSES:
        raise not_found()
    matched = state == "matched"
    value = score(renter, listing)
    return MapCard(
        item=DeckItem(
            listing=listing_out(listing, viewer, storage, matched=matched),
            score=value,
            band=score_band(value),
            summary=summary(renter, listing),
            reasons=reasons(renter, listing),
            distance_m=round(distance_from_pin(renter, listing)),
        ),
        state=state,
    )
