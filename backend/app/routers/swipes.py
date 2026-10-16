"""Swiping, undo, saved listings, the lister's deck and matches."""

import uuid

from fastapi import APIRouter, Query, Response

from app.deps import CurrentUser, DbSession, Storage
from app.schemas.swipes import (
    InterestedRenterPage,
    MatchPage,
    SavedPage,
    SwipeIn,
    SwipeOut,
    SwipeResult,
    UndoIn,
)
from app.services.listings import listing_out, matched_listing_ids
from app.services.swipes import (
    interested_renters,
    match_out,
    matches_for,
    record_swipe,
    save_listing,
    saved_listings,
    swipe_out,
    undo_swipe,
    unsave_listing,
)

router = APIRouter(tags=["swipes"])


@router.post("/swipes", response_model=SwipeResult)
def swipe(body: SwipeIn, user: CurrentUser, session: DbSession, storage: Storage) -> SwipeResult:
    """Like or pass. A lister's like on a renter who liked the listing makes a
    match. The same swipe sent again changes nothing (`created` is false)."""
    return record_swipe(session, user, body, storage)


@router.post("/swipes/undo", response_model=SwipeOut)
def undo(body: UndoIn, user: CurrentUser, session: DbSession) -> SwipeOut:
    """Take back the last swipe. Answers 404 `nothing_to_undo` if it is already gone."""
    return swipe_out(undo_swipe(session, user, body.swipe_id))


@router.get("/saved", response_model=SavedPage)
def list_saved(user: CurrentUser, session: DbSession, storage: Storage) -> SavedPage:
    matched = matched_listing_ids(session, user)
    return SavedPage(
        items=[
            listing_out(listing, user, storage, matched=listing.id in matched)
            for listing in saved_listings(session, user)
        ]
    )


@router.post("/saved/{listing_id}", status_code=204, response_class=Response)
def save(listing_id: uuid.UUID, user: CurrentUser, session: DbSession) -> Response:
    """Put a live listing aside. It leaves the deck until unsaved. Saving twice is fine."""
    save_listing(session, user, listing_id)
    return Response(status_code=204)


@router.delete("/saved/{listing_id}", status_code=204, response_class=Response)
def unsave(listing_id: uuid.UUID, user: CurrentUser, session: DbSession) -> Response:
    unsave_listing(session, user, listing_id)
    return Response(status_code=204)


@router.get("/listings/{listing_id}/deck/renters", response_model=InterestedRenterPage)
def listing_deck(
    listing_id: uuid.UUID,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    limit: int = Query(default=20, ge=1, le=50),
) -> InterestedRenterPage:
    """For the owner only: renters who liked this listing and still fit it."""
    return InterestedRenterPage(items=interested_renters(session, user, listing_id, storage, limit))


@router.get("/matches", response_model=MatchPage)
def list_matches(user: CurrentUser, session: DbSession, storage: Storage) -> MatchPage:
    return MatchPage(
        items=[match_out(match, user, storage) for match in matches_for(session, user)]
    )
