"""The renter's deck: listings in the area, filtered, scored and explained."""

from collections import Counter
from dataclasses import dataclass
from datetime import date

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.errors import ApiError
from app.models import Listing, RenterProfile, SavedListing, Swipe, User
from app.schemas.deck import Blocker, DeckDiagnostics, DeckItem
from app.services.listings import listing_out
from app.services.matching import (
    METERS_PER_MILE,
    Failure,
    Renter,
    distance_from_pin,
    failures,
    reasons,
    score,
    score_band,
    summary,
)
from app.services.storage import PhotoStorage

DEFAULT_LIMIT = 20


def public_point():
    """The listing's public point as a geography. Matches the index in migration 0005."""
    return func.geography(
        func.ST_SetSRID(func.ST_MakePoint(Listing.public_longitude, Listing.public_latitude), 4326)
    )


def renter_for(session: Session, user: User) -> Renter:
    """The signed-in user as a renter, or a 409 saying what to finish first."""
    if not user.profile_complete:
        raise ApiError(409, "profile_incomplete", "Finish your profile first.")
    profile = session.get(RenterProfile, user.id)
    from app.routers.renter_profile import is_complete

    if not is_complete(profile):
        raise ApiError(
            409,
            "renter_profile_incomplete",
            "Set up your search first: your dates, budget and area.",
        )
    return Renter.from_models(user, profile)


def candidates(
    session: Session, renter: Renter, today: date, include_seen: bool = False
) -> list[Listing]:
    """Live listings inside the renter's circle, from active accounts, not the
    renter's own, and not over yet. Nothing about fit is decided here.

    Listings the renter already swiped on or saved are left out unless
    `include_seen`."""
    pin = func.geography(
        func.ST_SetSRID(func.ST_MakePoint(renter.pin_longitude, renter.pin_latitude), 4326)
    )
    owner = select(User.id).where(User.status == "active")
    query = select(Listing).where(
        Listing.status == "active",
        Listing.owner_id != renter.user_id,
        Listing.owner_id.in_(owner),
        Listing.end_date >= today,
        Listing.public_latitude.is_not(None),
        func.ST_DWithin(public_point(), pin, renter.radius_m),
        # Phase 8 also leaves out blocked users.
    )
    if not include_seen:
        swiped = select(Swipe.listing_id).where(
            Swipe.side == "renter", Swipe.renter_id == renter.user_id
        )
        saved = select(SavedListing.listing_id).where(SavedListing.user_id == renter.user_id)
        query = query.where(Listing.id.not_in(swiped), Listing.id.not_in(saved))
    return list(session.scalars(query).unique().all())


@dataclass
class Scored:
    listing: Listing
    score: int


def deck(
    session: Session,
    viewer: User,
    renter: Renter,
    storage: PhotoStorage,
    today: date,
    limit: int = DEFAULT_LIMIT,
) -> list[DeckItem]:
    eligible = [
        listing
        for listing in candidates(session, renter, today)
        if not failures(renter, listing, listing.owner.school_id)
    ]
    ranked = sorted(
        (Scored(listing, score(renter, listing)) for listing in eligible),
        key=lambda item: (
            -item.score,
            -(item.listing.published_at.timestamp() if item.listing.published_at else 0),
            str(item.listing.id),
        ),
    )
    return [
        DeckItem(
            listing=listing_out(item.listing, viewer, storage),
            score=item.score,
            band=score_band(item.score),
            summary=summary(renter, item.listing),
            reasons=reasons(renter, item.listing),
            distance_m=round(distance_from_pin(renter, item.listing)),
        )
        for item in ranked[:limit]
    ]


def diagnose(session: Session, renter: Renter, today: date) -> DeckDiagnostics:
    """Why the deck is short: what keeps the most listings out."""
    found = candidates(session, renter, today)
    counts: Counter[Failure] = Counter()
    eligible = 0
    for listing in found:
        problems = failures(renter, listing, listing.owner.school_id)
        if not problems:
            eligible += 1
        counts.update(set(problems))

    blockers = [
        Blocker(
            field=failure.field,
            kind=failure.kind,
            removed=removed,
            message=_message(renter, failure, removed),
        )
        for failure, removed in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0].field))
    ]
    top_must_have = next((item for item in blockers if item.kind == "must_have"), None)
    seen = len(candidates(session, renter, today, include_seen=True)) - len(found)
    if not found and not seen:
        miles = renter.radius_m / METERS_PER_MILE
        area = Blocker(
            field="radius",
            kind="area",
            removed=0,
            message=f"No listings within {miles:.1f} miles of your pin yet. Try a bigger area.",
        )
        blockers.insert(0, area)
        top_must_have = area
    return DeckDiagnostics(
        in_area=len(found),
        eligible=eligible,
        seen=seen,
        top_must_have=top_must_have,
        blockers=blockers,
    )


# What each blocker does, as (one listing, several listings).
MUST_HAVE_PHRASES = {
    "space_type": ("isn't the type of space you chose", "aren't the type of space you chose"),
    "private_bathroom": ("doesn't have a private bathroom", "don't have a private bathroom"),
    "furnished": ("isn't furnished", "aren't furnished"),
    "laundry": ("doesn't have in-unit laundry", "don't have in-unit laundry"),
    "parking": ("doesn't have parking", "don't have parking"),
    "pet_free": ("allows pets", "allow pets"),
    "smoke_free": ("allows smoking", "allow smoking"),
    "housemate_count": ("has more than {value} staying", "have more than {value} staying"),
    "housemate_gender": ("isn't a household of {value}", "aren't households of {value}"),
}
LISTER_FILTER_PHRASES = {
    "pets": ("doesn't take pets.", "don't take pets."),
    "smoking": ("doesn't take smokers.", "don't take smokers."),
    "gender": ("is for a gender you don't match.", "are for a gender you don't match."),
    "gender_missing": (
        "has a gender preference. Add your gender in your profile to see the ones that fit you.",
        "have a gender preference. Add your gender in your profile to see the ones that fit you.",
    ),
    "school": (
        "is only for students of another school.",
        "are only for students of another school.",
    ),
    "dates": (
        "doesn't overlap your dates. More flexible dates would help.",
        "don't overlap your dates. More flexible dates would help.",
    ),
    "min_stay": (
        "needs a longer stay than your dates allow.",
        "need a longer stay than your dates allow.",
    ),
}


def _message(renter: Renter, failure: Failure, removed: int) -> str:
    """A sentence about one blocker, with what the renter could do about it."""
    one = removed == 1
    many = f"{removed} listing{'' if one else 's'}"
    if failure.kind == "must_have":
        value = next(
            (value for field, value, _ in renter.preferences if field == failure.field), None
        )
        if failure.field == "housemate_count":
            value = f"{value} housemate{'' if value == 1 else 's'}"
        phrase = MUST_HAVE_PHRASES[failure.field][0 if one else 1].format(value=value)
        # Must-haves are the renter's call: say what they rule out, never
        # suggest giving one up.
        return f"{many} nearby {phrase}."
    return f"{many} {LISTER_FILTER_PHRASES[failure.field][0 if one else 1]}"
