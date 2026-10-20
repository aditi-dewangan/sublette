"""Alerts for renters about listings, and the lister's weekly summary.

Three kinds, each about one listing:
* new_listing: a newly published place fits the renter's search ("Notify me").
* price_drop: a place the renter liked or saved lowered its rent.
* expiring: a place the renter liked or saved, without a match yet, comes
  off Sublette in two days.

Each student chooses how often (`users.alert_frequency`):
* instant: a push for each alert as it happens;
* daily (the default): at most one push a day. The first alert after a
  quiet day goes out at once; later ones wait and go out together in one
  digest when the day is up (the housekeeping thread sends it);
* off: nothing.

The same news is never sent twice: one new_listing and one expiring alert
per listing, and a second price drop before the first was sent updates it.
"""

import uuid
from datetime import datetime, timedelta

from sqlalchemy import and_, func, or_, select, update
from sqlalchemy.orm import Session

from app.models import Alert, Listing, Match, SavedListing, Swipe, User
from app.services.push import PushDispatcher, PushNote
from app.services.safety import blocked_with

DIGEST_EVERY = timedelta(days=1)
EXPIRING_IN_DAYS = 2
SUMMARY_EVERY = timedelta(days=7)

KIND_DATA = {"new_listing": "listing", "price_drop": "price_drop", "expiring": "expiring"}
KIND_TITLES = {
    "new_listing": "A new place fits your search",
    "price_drop": "Price dropped",
    "expiring": "Still interested?",
}


def dollars(cents: int) -> str:
    return f"${round(cents / 100):,}"


def interested_renters(session: Session, listing: Listing) -> list[User]:
    """Active renters who liked or saved the listing, and haven't blocked
    (or been blocked by) its lister."""
    liked = select(Swipe.renter_id).where(
        Swipe.side == "renter", Swipe.action == "like", Swipe.listing_id == listing.id
    )
    saved = select(SavedListing.user_id).where(SavedListing.listing_id == listing.id)
    return list(
        session.scalars(
            select(User).where(
                or_(User.id.in_(liked), User.id.in_(saved)),
                User.id != listing.owner_id,
                User.status == "active",
                User.id.not_in(blocked_with(listing.owner_id)),
            )
        ).unique()
    )


def raise_alert(
    session: Session,
    push: PushDispatcher,
    user: User,
    kind: str,
    listing: Listing,
    body: str,
    now: datetime,
    detail: dict | None = None,
) -> None:
    """Record an alert and send it as the student chose. Commits."""
    if user.alert_frequency == "off":
        return
    detail = {**(detail or {}), "body": body}
    earlier = select(Alert).where(
        Alert.user_id == user.id, Alert.kind == kind, Alert.listing_id == listing.id
    )
    if kind == "price_drop":
        waiting = session.scalar(earlier.where(Alert.sent_at.is_(None)))
        if waiting is not None:
            # Still waiting for the digest: say the newest price, from the first old one.
            waiting.detail = {**detail, "old_cents": waiting.detail.get("old_cents")}
            session.commit()
            return
    elif session.scalar(earlier.limit(1)) is not None:
        return

    instant = user.alert_frequency == "instant"
    session.add(
        Alert(
            user_id=user.id,
            kind=kind,
            listing_id=listing.id,
            detail=detail,
            created_at=now,
            sent_at=now if instant else None,
        )
    )
    session.commit()
    if instant:
        push.deliver(session, user.id, single_note(kind, listing.id, body))
    else:
        send_digest(session, push, user.id, now)


def single_note(kind: str, listing_id: uuid.UUID, body: str) -> PushNote:
    return PushNote(
        title=KIND_TITLES[kind],
        body=body,
        data={"kind": KIND_DATA[kind], "listing_id": str(listing_id), "role": "renter"},
    )


def digest_note(alerts: list[Alert]) -> PushNote:
    if len(alerts) == 1:
        only = alerts[0]
        return single_note(only.kind, only.listing_id, only.detail["body"])
    counts = {kind: sum(alert.kind == kind for alert in alerts) for kind in KIND_DATA}
    parts = []
    if counts["new_listing"]:
        n = counts["new_listing"]
        parts.append(f"{n} new place{'s' if n > 1 else ''} fit{'' if n > 1 else 's'} your search")
    if counts["price_drop"]:
        n = counts["price_drop"]
        parts.append(f"{n} price drop{'s' if n > 1 else ''}")
    if counts["expiring"]:
        n = counts["expiring"]
        parts.append(f"{n} place{'s' if n > 1 else ''} you liked closing soon")
    return PushNote(
        title="Your Sublette update",
        body=" · ".join(parts),
        data={"kind": "digest", "role": "renter"},
    )


def send_digest(session: Session, push: PushDispatcher, user_id: uuid.UUID, now: datetime) -> bool:
    """Send everything waiting for `user_id` in one push, if a day has passed
    since the last one. The day is claimed in one statement, so two alerts
    arriving at once can't both send. Commits."""
    waiting = session.scalars(
        select(Alert)
        .where(Alert.user_id == user_id, Alert.sent_at.is_(None))
        .order_by(Alert.created_at, Alert.id)
    ).all()
    if not waiting:
        return False
    claimed = session.execute(
        update(User)
        .where(
            User.id == user_id,
            or_(User.last_digest_at.is_(None), User.last_digest_at <= now - DIGEST_EVERY),
        )
        .values(last_digest_at=now)
        .returning(User.id)
    ).scalar()
    if claimed is None:
        session.rollback()
        return False
    for alert in waiting:
        alert.sent_at = now
    session.commit()
    push.deliver(session, user_id, digest_note(list(waiting)))
    return True


def alert_price_drop(
    push: PushDispatcher, listing_id: uuid.UUID, old_cents: int, new_cents: int, now: datetime
) -> None:
    """After an active listing's rent went down. Runs in the background."""

    def job(session: Session) -> None:
        listing = session.get(Listing, listing_id)
        if listing is None or listing.status != "active":
            return
        space = (listing.space_type or "place").replace("_", " ")
        body = f"A {space} you liked is now {dollars(new_cents)}/month (was {dollars(old_cents)})."
        for renter in interested_renters(session, listing):
            raise_alert(
                session,
                push,
                renter,
                "price_drop",
                listing,
                body,
                now,
                {"old_cents": old_cents, "new_cents": new_cents},
            )

    push.run(job)


# --- Run by the housekeeping thread -------------------------------------------------


def alert_expiring(session: Session, push: PushDispatcher, today, now: datetime) -> int:
    """Places coming off Sublette in two days: tell renters who liked or saved
    them and haven't matched. Safe to run often; each is told once."""
    soon = today + timedelta(days=EXPIRING_IN_DAYS)
    listings = session.scalars(
        select(Listing).where(
            Listing.status == "active",
            or_(
                Listing.expires_on == soon,
                and_(Listing.expires_on.is_(None), Listing.end_date == soon),
            ),
        )
    ).unique()
    told = 0
    for listing in listings:
        matched = set(
            session.scalars(select(Match.renter_id).where(Match.listing_id == listing.id))
        )
        for renter in interested_renters(session, listing):
            if renter.id in matched:
                continue
            raise_alert(
                session,
                push,
                renter,
                "expiring",
                listing,
                f"A place you liked comes off Sublette in {EXPIRING_IN_DAYS} days.",
                now,
            )
            told += 1
    return told


def send_due_digests(session: Session, push: PushDispatcher, now: datetime) -> int:
    """Digests whose day is up."""
    due = session.scalars(
        select(Alert.user_id)
        .join(User, User.id == Alert.user_id)
        .where(
            Alert.sent_at.is_(None),
            User.alert_frequency == "daily",
            User.status == "active",
            or_(User.last_digest_at.is_(None), User.last_digest_at <= now - DIGEST_EVERY),
        )
        .distinct()
    ).all()
    return sum(send_digest(session, push, user_id, now) for user_id in due)


def send_lister_summaries(session: Session, push: PushDispatcher, now: datetime) -> int:
    """Once a week, to listers with new likes they haven't answered:
    "3 renters liked your place this week"."""
    lister_swipe = Swipe.__table__.alias("lister_swipe")
    rows = session.execute(
        select(Listing.owner_id, func.count(func.distinct(Swipe.renter_id)))
        .select_from(Swipe)
        .join(Listing, Listing.id == Swipe.listing_id)
        .join(User, User.id == Listing.owner_id)
        .outerjoin(
            lister_swipe,
            and_(
                lister_swipe.c.side == "lister",
                lister_swipe.c.listing_id == Swipe.listing_id,
                lister_swipe.c.renter_id == Swipe.renter_id,
            ),
        )
        .where(
            Swipe.side == "renter",
            Swipe.action == "like",
            Swipe.created_at > now - SUMMARY_EVERY,
            lister_swipe.c.id.is_(None),
            Listing.status.in_(("active", "paused")),
            User.status == "active",
            User.alert_frequency != "off",
            or_(
                User.last_lister_summary_at.is_(None),
                User.last_lister_summary_at <= now - SUMMARY_EVERY,
            ),
        )
        .group_by(Listing.owner_id)
    ).all()
    for owner_id, likes in rows:
        session.execute(update(User).where(User.id == owner_id).values(last_lister_summary_at=now))
        session.commit()
        push.deliver(
            session,
            owner_id,
            PushNote(
                title=f"{likes} renter{'s' if likes > 1 else ''} liked your place this week",
                body="Swipe on them in Lister mode. A like back makes a match.",
                data={"kind": "likes", "role": "lister"},
            ),
        )
    return len(rows)
