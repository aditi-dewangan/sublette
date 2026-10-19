"""Renter mode: the map of listings around the pin."""

import uuid

from fastapi import APIRouter, Query

from app.deps import CurrentUser, DbSession, Now, Storage
from app.schemas.maps import MapCard, MapPage
from app.services.deck import renter_for
from app.services.maps import map_card, map_pins, parse_bbox

router = APIRouter(tags=["map"])


@router.get("/map/listings", response_model=MapPage)
def map_listings(
    user: CurrentUser,
    session: DbSession,
    now: Now,
    bbox: str = Query(description="min_lng,min_lat,max_lng,max_lat of the visible map"),
) -> MapPage:
    """Pins inside the visible map, matched first, then best fit. At most 500.

    New pins are the deck's listings. Only a matched listing's pin is at the
    real address; every other pin is the public point.
    """
    renter = renter_for(session, user)
    pins, truncated = map_pins(session, renter, parse_bbox(bbox), now.date())
    return MapPage(items=pins, truncated=truncated)


@router.get("/map/listings/{listing_id}", response_model=MapCard)
def map_listing(
    listing_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: Storage
) -> MapCard:
    """The card for one pin: the same as the deck's, with the pin's state."""
    renter = renter_for(session, user)
    return map_card(session, user, renter, listing_id, storage)
