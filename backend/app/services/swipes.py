"""Likes, passes, undo, saved listings and matches.

The rules:
* A renter may like a live listing that fits them, and pass on any live one.
* A lister may like or pass only on a renter who liked their listing and
  still fits it.
* A lister's like on such a renter makes the match, in the same transaction
  as the swipe. One match per renter and listing, enforced by the database.
* Each side swipes once per renter and listing. Sending the same swipe again,
  however fast or however late, changes nothing.
"""

import uuid

from sqlalchemy import delete, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.errors import ApiError
from app.models import Listing, Match, RenterProfile, SavedListing, Swipe, User
from app.schemas.swipes import (
    InterestedRenter,
    MatchOut,
    PersonOut,
    RenterCard,
    SwipeIn,
    SwipeOut,
    SwipeResult,
)
from app.services.deck import renter_for
from app.services.listings import listing_out, not_found
from app.services.matching import Renter, failures, lister_fits
from app.services.storage import PhotoStorage

LISTER_SWIPE_STATUSES = ("active", "paused")


def swipe_out(swipe: Swipe) -> SwipeOut:
    return SwipeOut(
        id=swipe.id,
        swipe_id=swipe.client_id,
        side=swipe.side,
        action=swipe.action,
        listing_id=swipe.listing_id,
        renter_id=swipe.renter_id,
        created_at=swipe.created_at,
    )


def _url(storage: PhotoStorage, key: str | None) -> str | None:
    return (storage.public_url(key) or None) if key else None


def person_out(user: User, storage: PhotoStorage) -> PersonOut:
    return PersonOut(
        id=user.id,
        first_name=user.first_name,
        photo_url=_url(storage, user.photo_key),
        school_name=user.school.display_name,
        verified=user.verified_at is not None,
    )


def match_out(match: Match, viewer: User, storage: PhotoStorage) -> MatchOut:
    return MatchOut(
        id=match.id,
        role="renter" if match.renter_id == viewer.id else "lister",
        listing=listing_out(match.listing, viewer, storage, matched=match.renter_id == viewer.id),
        renter=person_out(match.renter, storage),
        lister=person_out(match.lister, storage),
        created_at=match.created_at,
    )


def _find_match(session: Session, listing_id: uuid.UUID, renter_id: uuid.UUID) -> Match | None:
    return session.scalar(
        select(Match).where(Match.listing_id == listing_id, Match.renter_id == renter_id)
    )


def _result(
    session: Session, swipe: Swipe, viewer: User, storage: PhotoStorage, created: bool
) -> SwipeResult:
    match = _find_match(session, swipe.listing_id, swipe.renter_id)
    return SwipeResult(
        swipe=swipe_out(swipe),
        match=match_out(match, viewer, storage) if match else None,
        created=created,
    )


def _already(swipe: Swipe) -> ApiError:
    done = "liked" if swipe.action == "like" else "passed on"
    return ApiError(
        409,
        "already_swiped",
        f"You already {done} this. Undo your last swipe to change it.",
    )


def record_swipe(session: Session, user: User, body: SwipeIn, storage: PhotoStorage) -> SwipeResult:
    """Record a like or pass, and make the match when it is the second like.

    Commits. Safe to call with the same swipe any number of times, at once.
    """
    if body.swipe_id is not None:
        resent = session.scalar(select(Swipe).where(Swipe.client_id == body.swipe_id))
        if resent is not None:
            if resent.swiper_id != user.id or resent.listing_id != body.listing_id:
                raise ApiError(409, "swipe_id_taken", "That swipe id was already used.")
            return _result(session, resent, user, storage, created=False)

    listing = session.get(Listing, body.listing_id)
    if body.renter_id is None:
        side, renter_id = "renter", user.id
        _check_renter_swipe(session, user, listing, body)
    else:
        side, renter_id = "lister", body.renter_id
        _check_lister_swipe(session, user, listing, body)

    inserted = session.execute(
        insert(Swipe)
        .values(
            id=uuid.uuid4(),
            client_id=body.swipe_id,
            side=side,
            action=body.action,
            listing_id=body.listing_id,
            renter_id=renter_id,
            swiper_id=user.id,
        )
        .on_conflict_do_nothing()
        .returning(Swipe.id)
    ).scalar()

    swipe = session.scalar(
        select(Swipe).where(
            Swipe.side == side, Swipe.listing_id == body.listing_id, Swipe.renter_id == renter_id
        )
    )
    if inserted is None:
        # Already there: the same swipe sent twice is fine; the opposite one is not.
        session.rollback()
        if swipe is None or swipe.action != body.action:
            raise _already(swipe) if swipe else ApiError(409, "swipe_conflict", "Try again.")
        return _result(session, swipe, user, storage, created=False)

    if side == "lister" and body.action == "like":
        session.execute(
            insert(Match)
            .values(
                id=uuid.uuid4(),
                listing_id=listing.id,
                renter_id=renter_id,
                lister_id=user.id,
            )
            .on_conflict_do_nothing()
        )
    session.commit()
    return _result(session, swipe, user, storage, created=True)


def _check_renter_swipe(
    session: Session, user: User, listing: Listing | None, body: SwipeIn
) -> None:
    if listing is None or listing.status != "active":
        raise not_found()
    if listing.owner_id == user.id:
        raise ApiError(409, "own_listing", "That's your own listing.")
    renter = renter_for(session, user)
    if body.action == "like" and failures(renter, listing, listing.owner.school_id):
        raise ApiError(
            409, "listing_not_eligible", "This listing doesn't fit your search any more."
        )


def _check_lister_swipe(
    session: Session, user: User, listing: Listing | None, body: SwipeIn
) -> None:
    if listing is None or listing.owner_id != user.id:
        raise not_found()
    if listing.status not in LISTER_SWIPE_STATUSES:
        raise ApiError(409, "listing_closed", "This listing isn't live, so it can't match.")
    liked = session.scalar(
        select(Swipe.id).where(
            Swipe.side == "renter",
            Swipe.action == "like",
            Swipe.listing_id == listing.id,
            Swipe.renter_id == body.renter_id,
        )
    )
    if liked is None:
        raise ApiError(409, "renter_has_not_liked", "This renter hasn't liked your listing.")
    if body.action == "like" and _renter_if_eligible(session, body.renter_id, listing) is None:
        raise ApiError(409, "renter_not_eligible", "This renter no longer fits your listing.")


def _renter_if_eligible(
    session: Session, renter_id: uuid.UUID, listing: Listing
) -> tuple[User, RenterProfile, Renter] | None:
    user = session.get(User, renter_id)
    profile = session.get(RenterProfile, renter_id)
    from app.routers.renter_profile import is_complete

    if user is None or user.status != "active" or not user.profile_complete:
        return None
    if not is_complete(profile):
        return None
    renter = Renter.from_models(user, profile)
    if failures(renter, listing, listing.owner.school_id):
        return None
    return user, profile, renter


def undo_swipe(session: Session, user: User, swipe_id: uuid.UUID) -> Swipe:
    """Take back the caller's last swipe. Renter swipes count as one list;
    a lister's swipes count per listing. Commits."""
    swipe = session.scalar(
        select(Swipe).where(
            or_(Swipe.id == swipe_id, Swipe.client_id == swipe_id), Swipe.swiper_id == user.id
        )
    )
    if swipe is None:
        raise ApiError(404, "nothing_to_undo", "There's nothing to undo.")
    last = select(Swipe.id).where(Swipe.swiper_id == user.id, Swipe.side == swipe.side)
    if swipe.side == "lister":
        last = last.where(Swipe.listing_id == swipe.listing_id)
    latest = session.scalar(last.order_by(Swipe.created_at.desc(), Swipe.id.desc()).limit(1))
    if latest != swipe.id:
        raise ApiError(409, "not_last_swipe", "Only your last swipe can be undone.")
    if _find_match(session, swipe.listing_id, swipe.renter_id) is not None:
        raise ApiError(409, "already_matched", "You've matched, so this can't be undone.")
    session.delete(swipe)
    session.commit()
    return swipe


def save_listing(session: Session, user: User, listing_id: uuid.UUID) -> None:
    listing = session.get(Listing, listing_id)
    if listing is None or listing.status != "active" or listing.owner_id == user.id:
        raise not_found()
    session.execute(
        insert(SavedListing).values(user_id=user.id, listing_id=listing_id).on_conflict_do_nothing()
    )
    session.commit()


def unsave_listing(session: Session, user: User, listing_id: uuid.UUID) -> None:
    session.execute(
        delete(SavedListing).where(
            SavedListing.user_id == user.id, SavedListing.listing_id == listing_id
        )
    )
    session.commit()


def saved_listings(session: Session, user: User) -> list[Listing]:
    rows = session.scalars(
        select(SavedListing)
        .join(Listing, Listing.id == SavedListing.listing_id)
        .where(SavedListing.user_id == user.id, Listing.status == "active")
        .order_by(SavedListing.created_at.desc())
    ).unique()
    return [row.listing for row in rows]


def interested_renters(
    session: Session, owner: User, listing_id: uuid.UUID, storage: PhotoStorage, limit: int
) -> list[InterestedRenter]:
    """Renters who liked the listing, still fit it, and the lister hasn't swiped on."""
    listing = session.get(Listing, listing_id)
    if listing is None or listing.owner_id != owner.id:
        raise not_found()
    swiped = select(Swipe.renter_id).where(Swipe.side == "lister", Swipe.listing_id == listing_id)
    likes = session.scalars(
        select(Swipe)
        .where(
            Swipe.side == "renter",
            Swipe.action == "like",
            Swipe.listing_id == listing_id,
            Swipe.renter_id.not_in(swiped),
        )
        .order_by(Swipe.created_at.desc(), Swipe.id.desc())
    ).all()

    found = []
    for like in likes:
        eligible = _renter_if_eligible(session, like.renter_id, listing)
        if eligible is None:
            continue
        user, profile, renter = eligible
        found.append(
            InterestedRenter(
                renter=RenterCard(
                    id=user.id,
                    first_name=user.first_name,
                    photo_url=_url(storage, user.photo_key),
                    year=user.year,
                    program=user.program,
                    bio=user.bio,
                    school_name=user.school.display_name,
                    verified=user.verified_at is not None,
                ),
                start_date=profile.start_date,
                end_date=profile.end_date,
                liked_at=like.created_at,
                fits=lister_fits(renter, listing, user.school.display_name),
            )
        )
        if len(found) >= limit:
            break
    return found


def matches_for(session: Session, user: User) -> list[Match]:
    return list(
        session.scalars(
            select(Match)
            .where(or_(Match.renter_id == user.id, Match.lister_id == user.id))
            .order_by(Match.created_at.desc(), Match.id.desc())
        ).unique()
    )
