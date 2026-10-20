"""Reports, blocks, scam flags and per-account rate limits.

The rules:
* Every profile, listing and message can be reported. A report goes to the
  review queue on the admin page; reporting the same thing twice keeps one.
* A block hides two people from each other everywhere, whichever of them
  made it: decks, the map, saved listings, matches and chats. The queries
  that show people or listings call `blocked_with` for this.
* The server flags payment requests and outside links in the first three
  messages of a chat, and one photo on two people's listings. Flags go to the
  same queue as reports; nothing is hidden or held back because of one.
"""

import re
import uuid
from datetime import datetime, timedelta

from sqlalchemy import case, func, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.config import Settings
from app.errors import ApiError
from app.models import Block, Listing, Match, Message, Report, User
from app.schemas.safety import BlockIn, ReportIn
from app.services import rate_limit

# Scam flags look at this many messages at the start of each chat.
FIRST_MESSAGES = 3

PAYMENT_PATTERN = re.compile(
    r"\b("
    r"venmo|zelle|cash\s?app|paypal|western\s+union|moneygram|"
    r"wire\s+(?:transfer|the|me|you|money|it)|wired|"
    r"gift\s?cards?|bitcoin|btc|crypto|usdt|apple\s+pay|google\s+pay|"
    r"pay\s+(?:the\s+|a\s+|your\s+)?deposit|"
    r"send\s+(?:me\s+)?(?:the\s+|a\s+|your\s+)?(?:deposit|money|payment)"
    r")\b",
    re.IGNORECASE,
)
LINK_PATTERN = re.compile(
    r"(https?://|\bwww\.|\b[a-z0-9-]+\.(?:com|net|org|io|co|me|ly|link|xyz|app|info|biz"
    r"|site|online|shop|top)\b)",
    re.IGNORECASE,
)

DAY = timedelta(days=1)


# --- Blocks --------------------------------------------------------------------------


def blocked_with(user_id: uuid.UUID):
    """A subquery of everyone `user_id` blocked or was blocked by."""
    return select(
        case((Block.blocker_id == user_id, Block.blocked_id), else_=Block.blocker_id)
    ).where(or_(Block.blocker_id == user_id, Block.blocked_id == user_id))


def is_blocked(session: Session, first: uuid.UUID, second: uuid.UUID) -> bool:
    return (
        session.scalar(
            select(func.count())
            .select_from(Block)
            .where(
                or_(
                    (Block.blocker_id == first) & (Block.blocked_id == second),
                    (Block.blocker_id == second) & (Block.blocked_id == first),
                )
            )
        )
        > 0
    )


def _person(session: Session, user_id: uuid.UUID) -> User:
    user = session.get(User, user_id)
    if user is None or user.verified_at is None:
        raise ApiError(404, "user_not_found", "That person isn't on Sublette.")
    return user


def block_target(session: Session, viewer: User, body: BlockIn) -> User:
    """The person to block: named directly, or as the owner of a listing (so
    blocking from a listing card needs no user id)."""
    if body.listing_id is not None:
        listing = session.get(Listing, body.listing_id)
        if listing is None:
            raise ApiError(404, "listing_not_found", "That listing isn't available.")
        target = listing.owner
    else:
        target = _person(session, body.user_id)
    if target.id == viewer.id:
        raise ApiError(422, "cant_block_yourself", "You can't block yourself.")
    return target


def block(session: Session, viewer: User, target: User, now: datetime) -> list[Match]:
    """Block `target`. Blocking twice is harmless. Returns the pair's matches,
    which both people's apps should now drop. Commits."""
    session.execute(
        insert(Block)
        .values(blocker_id=viewer.id, blocked_id=target.id, created_at=now)
        .on_conflict_do_nothing()
    )
    session.commit()
    return list(
        session.scalars(
            select(Match).where(
                or_(
                    (Match.renter_id == viewer.id) & (Match.lister_id == target.id),
                    (Match.renter_id == target.id) & (Match.lister_id == viewer.id),
                )
            )
        ).unique()
    )


# --- Reports -------------------------------------------------------------------------


def _listing_excerpt(listing: Listing) -> str:
    parts = [
        (listing.space_type or "space").replace("_", " "),
        f"${round(listing.rent_cents / 100):,}/month" if listing.rent_cents else None,
        f"{listing.start_date} to {listing.end_date}" if listing.start_date else None,
        listing.housemates_note,
    ]
    return " · ".join(part for part in parts if part)


def report(
    session: Session, settings: Settings, reporter: User, body: ReportIn, now: datetime
) -> tuple[Report, bool]:
    """File a report. Returns it and whether it is new: the same open report
    again is not filed twice. Commits."""
    listing_id = message_id = None
    excerpt = None
    if body.target == "user":
        subject = _person(session, body.id)
    elif body.target == "listing":
        listing = session.get(Listing, body.id)
        if listing is None or listing.status == "draft":
            raise ApiError(404, "listing_not_found", "That listing isn't available.")
        subject, listing_id, excerpt = listing.owner, listing.id, _listing_excerpt(listing)
    else:
        message = session.get(Message, body.id)
        match = session.get(Match, message.match_id) if message else None
        if match is None or reporter.id not in (match.renter_id, match.lister_id):
            raise ApiError(404, "message_not_found", "That message isn't available.")
        subject = _person(session, message.sender_id)
        listing_id, message_id, excerpt = match.listing_id, message.id, message.body
    if subject.id == reporter.id:
        raise ApiError(422, "cant_report_yourself", "You can't report yourself.")

    def already_open() -> Report | None:
        return session.scalar(
            select(Report).where(
                Report.reporter_id == reporter.id,
                Report.target == body.target,
                Report.target_id == body.id,
                Report.status == "open",
            )
        )

    existing = already_open()
    if existing is not None:
        return existing, False

    rate_limit.hit(
        session,
        f"reports:{reporter.id}",
        limit=settings.reports_per_day,
        window=DAY,
        now=now,
    )
    report_id = session.execute(
        insert(Report)
        .values(
            id=uuid.uuid4(),
            source="user",
            reporter_id=reporter.id,
            subject_id=subject.id,
            subject_email=subject.email,
            target=body.target,
            target_id=body.id,
            listing_id=listing_id,
            message_id=message_id,
            reason=body.reason,
            details=body.details or None,
            excerpt=excerpt,
            status="open",
            created_at=now,
        )
        .on_conflict_do_nothing(
            index_elements=["reporter_id", "target", "target_id"],
            index_where=(Report.status == "open") & Report.reporter_id.is_not(None),
        )
        .returning(Report.id)
    ).scalar()
    if report_id is None:
        # The same report, sent at the same moment, got there first.
        session.rollback()
        return already_open(), False
    session.commit()
    return session.get(Report, report_id), True


def scam_reasons(text: str) -> list[str]:
    """Which automatic flags a message raises, if any."""
    found = []
    if PAYMENT_PATTERN.search(text):
        found.append("payment_request")
    if LINK_PATTERN.search(text):
        found.append("outside_link")
    return found


FLAG_DETAILS = {
    "payment_request": "Mentions a payment app, wire transfer or deposit early in the chat.",
    "outside_link": "Has a link to somewhere outside Sublette early in the chat.",
}


def flag_message(session: Session, match: Match, message: Message, now: datetime) -> list[Report]:
    """Flag a payment request or outside link in one of a chat's first
    messages. The caller commits."""
    earlier = session.scalar(
        select(func.count()).where(Message.match_id == match.id, Message.seq < message.seq)
    )
    if earlier >= FIRST_MESSAGES:
        return []
    sender = session.get(User, message.sender_id)
    flags = [
        Report(
            id=uuid.uuid4(),
            source="automatic",
            subject_id=message.sender_id,
            subject_email=sender.email,
            target="message",
            target_id=message.id,
            listing_id=match.listing_id,
            message_id=message.id,
            reason=reason,
            details=FLAG_DETAILS[reason],
            excerpt=message.body,
            status="open",
            created_at=now,
        )
        for reason in scam_reasons(message.body)
    ]
    session.add_all(flags)
    return flags


# --- Rate limits ---------------------------------------------------------------------


def limit_swipes(session: Session, settings: Settings, user: User, now: datetime) -> None:
    rate_limit.hit(
        session,
        f"swipes:{user.id}",
        limit=settings.swipes_per_hour,
        window=timedelta(hours=1),
        now=now,
    )


def limit_messages(session: Session, settings: Settings, user: User, now: datetime) -> None:
    rate_limit.hit(
        session,
        f"messages:minute:{user.id}",
        limit=settings.messages_per_minute,
        window=timedelta(minutes=1),
        now=now,
    )
    rate_limit.hit(
        session,
        f"messages:day:{user.id}",
        limit=settings.messages_per_day,
        window=DAY,
        now=now,
    )


def limit_listings(session: Session, settings: Settings, user: User, now: datetime) -> None:
    rate_limit.hit(
        session,
        f"listings:{user.id}",
        limit=settings.listings_per_day,
        window=DAY,
        now=now,
    )
