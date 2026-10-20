"""Chat, the checklist and "Filled" for one match.

The rules:
* Only the two people in a match can read or write anything here. Anyone else
  gets 403, whether or not the match exists, so ids can't be probed.
* Once either of the two blocks the other, the chat is gone for both (404)
  and leaves both Matches lists.
* There is no other way to message someone: no match, no chat.
* A message sent twice with the same `message_id` is stored once.
* Either side can tick the checklist. The lister's "Filled" closes the listing
  (it leaves every deck and the map); both sides' "Filled" makes a completed
  sublet, counted on each profile.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import case, func, or_, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.config import Settings
from app.errors import ApiError
from app.models import Match, Message, User
from app.schemas.chat import Checklist, ChecklistPatch, Filled, MessageOut, MessagePage
from app.services.safety import blocked_with, flag_message, is_blocked, limit_messages

CHECKLIST_STEPS = ("tour_done", "landlord_consent_confirmed", "dates_agreed", "sublease_signed")
# A listing in any of these can still be marked filled from its chat.
FILLABLE = ("active", "paused", "expired")


def forbidden() -> ApiError:
    return ApiError(403, "not_your_match", "This chat is only for the two people who matched.")


def role_in(match: Match, user: User) -> str:
    return "renter" if match.renter_id == user.id else "lister"


def member_match(session: Session, user: User, match_id: uuid.UUID, lock: bool = False) -> Match:
    """The match, if `user` is one of its two people. 403 otherwise."""
    if lock:
        # Lock the row alone: the joined listing and users are outer joins,
        # which PostgreSQL can't lock.
        session.execute(select(Match.id).where(Match.id == match_id).with_for_update())
    match = session.get(Match, match_id)
    if match is None or user.id not in (match.renter_id, match.lister_id):
        raise forbidden()
    if is_blocked(session, match.renter_id, match.lister_id):
        raise ApiError(404, "chat_unavailable", "This chat isn't available any more.")
    return match


def other_side(match: Match, user: User) -> uuid.UUID:
    return match.lister_id if match.renter_id == user.id else match.renter_id


def message_out(message: Message, viewer_id: uuid.UUID) -> MessageOut:
    return MessageOut(
        id=message.id,
        message_id=message.client_id,
        match_id=message.match_id,
        sender_id=message.sender_id,
        mine=message.sender_id == viewer_id,
        body=message.body,
        created_at=message.created_at,
    )


def checklist_out(match: Match) -> Checklist:
    return Checklist(
        tour_done=match.tour_done,
        landlord_consent_confirmed=match.landlord_consent_confirmed,
        dates_agreed=match.dates_agreed,
        sublease_signed=match.sublease_signed,
        updated_at=match.checklist_updated_at,
    )


def filled_out(match: Match) -> Filled:
    return Filled(
        renter_confirmed=match.renter_filled_at is not None,
        lister_confirmed=match.lister_filled_at is not None,
        completed=match.renter_filled_at is not None and match.lister_filled_at is not None,
    )


@dataclass(frozen=True)
class Activity:
    """What the Matches list shows about a chat for one of its two people."""

    unread: int = 0
    last_message: Message | None = None


def activity_for(session: Session, user: User, match_ids: list[uuid.UUID]) -> dict:
    """Unread count and last message for each of the user's matches."""
    if not match_ids:
        return {}
    read_up_to = case(
        (Match.renter_id == user.id, Match.renter_read_seq), else_=Match.lister_read_seq
    )
    unread = dict(
        session.execute(
            select(Message.match_id, func.count())
            .join(Match, Match.id == Message.match_id)
            .where(
                Message.match_id.in_(match_ids),
                Message.sender_id != user.id,
                Message.seq > read_up_to,
            )
            .group_by(Message.match_id)
        ).all()
    )
    last = {
        message.match_id: message
        for message in session.scalars(
            select(Message)
            .where(Message.match_id.in_(match_ids))
            .order_by(Message.match_id, Message.seq.desc())
            .distinct(Message.match_id)
        )
    }
    return {
        match_id: Activity(unread=unread.get(match_id, 0), last_message=last.get(match_id))
        for match_id in match_ids
    }


def send_message(
    session: Session,
    settings: Settings,
    user: User,
    match: Match,
    body: str,
    client_id: uuid.UUID | None,
    now: datetime,
) -> tuple[Message, bool]:
    """Store a message. Returns it and whether it is new. Commits."""
    body = body.strip()
    if not body:
        raise ApiError(422, "message_empty", "Write a message first.")
    if client_id is not None:
        resent = session.scalar(select(Message).where(Message.client_id == client_id))
        if resent is not None:
            if resent.sender_id != user.id or resent.match_id != match.id:
                raise ApiError(409, "message_id_taken", "That message id was already used.")
            return resent, False

    limit_messages(session, settings, user, now)
    message_id = session.execute(
        insert(Message)
        .values(
            id=uuid.uuid4(),
            client_id=client_id,
            match_id=match.id,
            sender_id=user.id,
            body=body,
            created_at=now,
        )
        .on_conflict_do_nothing(index_elements=["client_id"])
        .returning(Message.id)
    ).scalar()
    if message_id is None:
        # The same message arrived twice at the same moment; the other copy won.
        session.rollback()
        return session.scalar(select(Message).where(Message.client_id == client_id)), False

    message = session.get(Message, message_id)
    match.last_message_at = now
    # Your own message is read.
    _set_read(match, user, message.seq)
    flag_message(session, match, message, now)
    session.commit()
    return message, True


def _set_read(match: Match, user: User, seq: int) -> None:
    if match.renter_id == user.id:
        match.renter_read_seq = max(match.renter_read_seq, seq)
    else:
        match.lister_read_seq = max(match.lister_read_seq, seq)


def message_page(
    session: Session, user: User, match: Match, before: uuid.UUID | None, limit: int
) -> MessagePage:
    query = select(Message).where(Message.match_id == match.id)
    if before is not None:
        anchor = session.scalar(
            select(Message.seq).where(Message.id == before, Message.match_id == match.id)
        )
        if anchor is None:
            raise ApiError(400, "invalid_cursor", "That page link is no longer valid.")
        query = query.where(Message.seq < anchor)
    rows = session.scalars(query.order_by(Message.seq.desc()).limit(limit + 1)).all()
    page = list(reversed(rows[:limit]))
    return MessagePage(
        items=[message_out(message, user.id) for message in page], has_more=len(rows) > limit
    )


def mark_read(session: Session, user: User, match: Match) -> None:
    """Everything in the chat so far is read. Commits."""
    latest = session.scalar(select(func.max(Message.seq)).where(Message.match_id == match.id))
    if latest is not None:
        _set_read(match, user, latest)
        session.commit()


def update_checklist(match: Match, patch: ChecklistPatch, now: datetime) -> bool:
    """Apply the steps that were sent. Returns whether anything changed. The
    caller commits."""
    changed = False
    for step, value in patch.model_dump(exclude_none=True).items():
        if getattr(match, step) != value:
            setattr(match, step, value)
            changed = True
    if changed:
        match.checklist_updated_at = now
    return changed


def confirm_filled(session: Session, user: User, match: Match, now: datetime) -> bool:
    """Record the caller's "Filled". Returns whether anything changed. The
    caller locked the match and commits.

    The lister's confirmation marks the listing filled. When the second side
    confirms, both people get a completed sublet.
    """
    was_completed = filled_out(match).completed
    changed = False
    if role_in(match, user) == "lister":
        if match.lister_filled_at is None:
            match.lister_filled_at = now
            changed = True
        listing = match.listing
        if listing.status != "filled":
            if listing.status not in FILLABLE:
                raise ApiError(409, "listing_closed", "This listing can't be marked filled.")
            listing.status = "filled"
            changed = True
    elif match.renter_filled_at is None:
        match.renter_filled_at = now
        changed = True

    if not was_completed and filled_out(match).completed:
        session.execute(
            update(User)
            .where(User.id.in_((match.renter_id, match.lister_id)))
            .values(completed_sublets=User.completed_sublets + 1)
        )
    return changed


def matches_newest_activity_first(session: Session, user: User) -> list[Match]:
    return list(
        session.scalars(
            select(Match)
            .where(
                or_(Match.renter_id == user.id, Match.lister_id == user.id),
                Match.renter_id.not_in(blocked_with(user.id)),
                Match.lister_id.not_in(blocked_with(user.id)),
            )
            .order_by(
                func.coalesce(Match.last_message_at, Match.created_at).desc(), Match.id.desc()
            )
        ).unique()
    )
