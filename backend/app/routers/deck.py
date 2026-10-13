"""Renter mode: the deck of listings to swipe on."""

from fastapi import APIRouter, Query

from app.deps import CurrentUser, DbSession, Now, Storage
from app.schemas.deck import DeckDiagnostics, DeckPage
from app.services.deck import DEFAULT_LIMIT, deck, diagnose, renter_for

router = APIRouter(tags=["deck"])


@router.get("/deck/listings", response_model=DeckPage)
def deck_listings(
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    now: Now,
    limit: int = Query(default=DEFAULT_LIMIT, ge=1, le=50),
) -> DeckPage:
    """Listings the renter may see inside their circle, best fit first.

    Never includes a listing that fails a must-have or a lister's filter,
    whatever its score. Answers 409 until the profile and search are set up.
    """
    renter = renter_for(session, user)
    return DeckPage(items=deck(session, user, renter, storage, now.date(), limit))


@router.get("/deck/diagnostics", response_model=DeckDiagnostics)
def deck_diagnostics(user: CurrentUser, session: DbSession, now: Now) -> DeckDiagnostics:
    """Why the deck is short, and the must-have that keeps out the most listings."""
    renter = renter_for(session, user)
    return diagnose(session, renter, now.date())
