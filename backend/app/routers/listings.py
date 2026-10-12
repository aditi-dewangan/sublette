"""Lister mode: create, edit, publish, pause and fill a listing."""

import base64
import uuid
from datetime import datetime

from fastapi import APIRouter, Query
from sqlalchemy import and_, or_, select

from app.deps import CurrentUser, DbSession, Now, Storage
from app.errors import ApiError
from app.models import Listing
from app.schemas.listings import ListingFields, ListingOut, ListingPage, StatusChange
from app.services.listings import (
    apply_fields,
    listing_out,
    new_listing,
    not_found,
    require_publishable,
)

router = APIRouter(tags=["listings"])

# What a listing may change to from each status. Expiry (phase 8) is set by the server.
TRANSITIONS = {
    "draft": {"active"},
    "active": {"paused", "filled"},
    "paused": {"active", "filled"},
    "filled": set(),
    "expired": {"active"},
}


def _own_listing(session: DbSession, listing_id: uuid.UUID, user: CurrentUser) -> Listing:
    """The caller's own listing. Someone else's is reported as not found, so
    nobody can learn which ids exist."""
    listing = session.get(Listing, listing_id)
    if listing is None or listing.owner_id != user.id:
        raise not_found()
    return listing


def _delete_photos(storage: Storage, keys: list[str]) -> None:
    for key in keys:
        storage.delete(key)


@router.post("/listings", status_code=201, response_model=ListingOut)
def create_listing(
    fields: ListingFields, user: CurrentUser, session: DbSession, storage: Storage
) -> ListingOut:
    """Start a listing as a draft. Any answers may be filled in later."""
    listing = new_listing(user)
    session.add(listing)
    apply_fields(session, listing, user, fields, storage)
    session.commit()
    session.refresh(listing)
    return listing_out(listing, user, storage)


@router.get("/me/listings", response_model=ListingPage)
def my_listings(
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    cursor: str | None = None,
    limit: int = Query(default=20, ge=1, le=100),
) -> ListingPage:
    """The caller's own listings, newest first, in every status."""
    query = select(Listing).where(Listing.owner_id == user.id)
    if cursor:
        created_at, last_id = _read_cursor(cursor)
        query = query.where(
            or_(
                Listing.created_at < created_at,
                and_(Listing.created_at == created_at, Listing.id < last_id),
            )
        )
    rows = session.scalars(
        query.order_by(Listing.created_at.desc(), Listing.id.desc()).limit(limit + 1)
    ).all()
    page = rows[:limit]
    next_cursor = _make_cursor(page[-1]) if len(rows) > limit else None
    return ListingPage(
        items=[listing_out(listing, user, storage) for listing in page], next_cursor=next_cursor
    )


@router.get("/listings/{listing_id}", response_model=ListingOut)
def read_listing(
    listing_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: Storage
) -> ListingOut:
    """Any verified student may read an active listing; only the owner sees
    the exact address, and only the owner sees drafts, paused and filled ones."""
    listing = session.get(Listing, listing_id)
    if listing is None or (listing.owner_id != user.id and listing.status != "active"):
        raise not_found()
    return listing_out(listing, user, storage)


@router.patch("/listings/{listing_id}", response_model=ListingOut)
def update_listing(
    listing_id: uuid.UUID,
    fields: ListingFields,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    now: Now,
) -> ListingOut:
    """Change any answers. A listing renters can see must stay complete."""
    listing = _own_listing(session, listing_id, user)
    if listing.status == "filled":
        raise ApiError(409, "listing_filled", "This listing is filled and can't be changed.")
    removed = apply_fields(session, listing, user, fields, storage)
    if listing.status in ("active", "paused"):
        require_publishable(listing, now.date())
    session.commit()
    session.refresh(listing)
    _delete_photos(storage, removed)
    return listing_out(listing, user, storage)


@router.post("/listings/{listing_id}/status", response_model=ListingOut)
def change_status(
    listing_id: uuid.UUID,
    change: StatusChange,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    now: Now,
) -> ListingOut:
    """Publish (active), pause, or mark filled."""
    listing = _own_listing(session, listing_id, user)
    target = change.status
    if target != listing.status:
        if target not in TRANSITIONS[listing.status]:
            message = {
                "filled": "This listing is filled and can't be changed.",
                "draft": "Publish the listing before pausing it or marking it filled.",
            }.get(listing.status, f"A {listing.status} listing can't become {target}.")
            raise ApiError(409, "invalid_status_change", message)
        if target == "active":
            require_publishable(listing, now.date())
            if listing.published_at is None:
                listing.published_at = now
        listing.status = target
        session.commit()
        session.refresh(listing)
    return listing_out(listing, user, storage)


def _make_cursor(listing: Listing) -> str:
    raw = f"{listing.created_at.isoformat()}|{listing.id}"
    return base64.urlsafe_b64encode(raw.encode()).decode()


def _read_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        created_at, last_id = base64.urlsafe_b64decode(cursor.encode()).decode().split("|")
        return datetime.fromisoformat(created_at), uuid.UUID(last_id)
    except (ValueError, UnicodeDecodeError) as error:
        raise ApiError(400, "invalid_cursor", "That page link is no longer valid.") from error
