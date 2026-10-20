"""The funnel and feature use, recorded so the business model can be chosen
from real numbers (build plan, phase 9).

The server records the funnel itself, where each step happens: signed_up,
profile_completed, first_swipe, first_match, listing_published,
listing_first_match and listing_filled (with the days since publishing). The
app adds app_opened (for crash-free sessions) and feature_used.

Recording is part of the request's own transaction and never fails it: a
step recorded twice is simply kept once.
"""

import uuid
from datetime import datetime, timedelta
from statistics import median

from sqlalchemy import and_, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.models import CrashReport, Event, Listing, Swipe
from app.models.analytics import ONCE_PER_LISTING, ONCE_PER_USER

# Features the app may report as used.
FEATURES = (
    "deck",
    "map",
    "matches",
    "chat",
    "saved",
    "undo",
    "notify_me",
    "bigger_area",
    "share_listing",
    "referral",
    "settings",
    "report",
    "block",
)
FUNNEL = ("signed_up", "profile_completed", "first_swipe", "first_match", "listing_filled")
NO_RESPONSE_AFTER = timedelta(days=7)


def record(
    session: Session,
    name: str,
    now: datetime,
    *,
    user_id: uuid.UUID | None = None,
    listing_id: uuid.UUID | None = None,
    detail: str | None = None,
    value: float | None = None,
) -> None:
    """Add one event to the caller's transaction. Steps that happen once per
    account or listing are kept once."""
    statement = insert(Event).values(
        name=name,
        user_id=user_id,
        listing_id=listing_id,
        detail=detail,
        value=value,
        created_at=now,
    )
    if name in ONCE_PER_USER:
        statement = statement.on_conflict_do_nothing(
            index_elements=["user_id", "name"], index_where=Event.name.in_(ONCE_PER_USER)
        )
    elif name in ONCE_PER_LISTING:
        statement = statement.on_conflict_do_nothing(
            index_elements=["listing_id", "name"], index_where=Event.name.in_(ONCE_PER_LISTING)
        )
    session.execute(statement)


def days_since_published(listing: Listing, now: datetime) -> float | None:
    if listing.published_at is None:
        return None
    return round((now - listing.published_at).total_seconds() / 86400, 2)


def record_match(session: Session, renter_id, lister_id, listing: Listing, now: datetime) -> None:
    for person in (renter_id, lister_id):
        record(session, "first_match", now, user_id=person)
    record(
        session,
        "listing_first_match",
        now,
        listing_id=listing.id,
        user_id=lister_id,
        value=days_since_published(listing, now),
    )


# --- What the admin page shows -------------------------------------------------------


def _distinct_users(session: Session, name: str, since: datetime) -> int:
    """Accounts (or, for listing steps, listings) that reached a step."""
    return (
        session.scalar(
            select(func.count(func.distinct(func.coalesce(Event.listing_id, Event.user_id)))).where(
                Event.name == name, Event.created_at >= since
            )
        )
        or 0
    )


def _median(session: Session, name: str, since: datetime) -> float | None:
    values = session.scalars(
        select(Event.value).where(
            Event.name == name, Event.created_at >= since, Event.value.is_not(None)
        )
    ).all()
    return round(median(values), 1) if values else None


def metrics(session: Session, now: datetime, days: int = 30) -> dict:
    since = now - timedelta(days=days)
    funnel = [(name, _distinct_users(session, name, since)) for name in FUNNEL]
    features = session.execute(
        select(Event.detail, func.count())
        .where(Event.name == "feature_used", Event.created_at >= since)
        .group_by(Event.detail)
        .order_by(func.count().desc())
    ).all()

    # Likes older than a week that the lister never answered (liked or passed).
    liked = Swipe.__table__.alias("liked")
    lister = Swipe.__table__.alias("lister")
    unanswered = session.scalar(
        select(func.count())
        .select_from(liked)
        .outerjoin(
            lister,
            and_(
                lister.c.side == "lister",
                lister.c.listing_id == liked.c.listing_id,
                lister.c.renter_id == liked.c.renter_id,
            ),
        )
        .where(
            liked.c.side == "renter",
            liked.c.action == "like",
            liked.c.created_at < now - NO_RESPONSE_AFTER,
            liked.c.created_at >= since - NO_RESPONSE_AFTER,
            lister.c.id.is_(None),
        )
    )
    likes = session.scalar(
        select(func.count())
        .select_from(liked)
        .where(
            liked.c.side == "renter",
            liked.c.action == "like",
            liked.c.created_at < now - NO_RESPONSE_AFTER,
            liked.c.created_at >= since - NO_RESPONSE_AFTER,
        )
    )

    sessions = session.scalar(
        select(func.count()).where(Event.name == "app_opened", Event.created_at >= since)
    )
    crashes = session.scalar(
        select(func.count()).where(CrashReport.kind == "crash", CrashReport.created_at >= since)
    )
    crash_free = None
    if sessions:
        crash_free = round(100 * max(0, sessions - crashes) / sessions, 2)
    return {
        "days": days,
        "funnel": funnel,
        "median_days_to_first_match": _median(session, "listing_first_match", since),
        "median_days_to_filled": _median(session, "listing_filled", since),
        "listings_published": _distinct_users(session, "listing_published", since),
        "likes_without_response": unanswered or 0,
        "likes_old_enough": likes or 0,
        "features": [(detail or "unknown", count) for detail, count in features],
        "sessions": sessions or 0,
        "crashes": crashes or 0,
        "crash_free_percent": crash_free,
    }
