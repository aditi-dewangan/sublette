"""Matches, chat, the shared checklist and "Filled"."""

import uuid

from fastapi import APIRouter, Query, Response

from app.deps import AppSettings, CurrentUser, DbSession, Live, Now, Push, Storage
from app.schemas.chat import ChecklistPatch, MessageIn, MessageOut, MessagePage
from app.schemas.swipes import MatchOut, MatchPage
from app.services.chat import (
    activity_for,
    confirm_filled,
    mark_read,
    matches_newest_activity_first,
    member_match,
    message_out,
    message_page,
    send_message,
    update_checklist,
)
from app.services.notify import announce_match_change, announce_message
from app.services.swipes import match_out

router = APIRouter(tags=["chat"])


def _one(session: DbSession, user: CurrentUser, storage: Storage, match) -> MatchOut:
    return match_out(match, user, storage, activity_for(session, user, [match.id])[match.id])


@router.get("/matches", response_model=MatchPage)
def list_matches(user: CurrentUser, session: DbSession, storage: Storage) -> MatchPage:
    matches = matches_newest_activity_first(session, user)
    activity = activity_for(session, user, [match.id for match in matches])
    return MatchPage(
        items=[match_out(match, user, storage, activity[match.id]) for match in matches]
    )


@router.get("/matches/{match_id}", response_model=MatchOut)
def read_match(
    match_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: Storage
) -> MatchOut:
    """One match, for opening its chat from a notification."""
    return _one(session, user, storage, member_match(session, user, match_id))


@router.get("/matches/{match_id}/messages", response_model=MessagePage)
def list_messages(
    match_id: uuid.UUID,
    user: CurrentUser,
    session: DbSession,
    before: uuid.UUID | None = None,
    limit: int = Query(default=50, ge=1, le=100),
) -> MessagePage:
    """The latest messages, oldest first. Pass `before` (a message id) for older ones."""
    match = member_match(session, user, match_id)
    return message_page(session, user, match, before, limit)


@router.post("/matches/{match_id}/messages", status_code=201, response_model=MessageOut)
def post_message(
    match_id: uuid.UUID,
    body: MessageIn,
    response: Response,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    live: Live,
    push: Push,
    settings: AppSettings,
    now: Now,
) -> MessageOut:
    """Send a message. The same `message_id` again answers 200 with the
    first copy and sends nothing new."""
    # Locked so messages commit in the order of their `seq`: otherwise a
    # reader could mark a later one read before an earlier one appears.
    match = member_match(session, user, match_id, lock=True)
    message, created = send_message(session, settings, user, match, body.body, body.message_id, now)
    if created:
        announce_message(session, live, push, storage, match, message)
    else:
        response.status_code = 200
    return message_out(message, user.id)


@router.post("/matches/{match_id}/read", status_code=204, response_class=Response)
def read_messages(match_id: uuid.UUID, user: CurrentUser, session: DbSession) -> Response:
    """Everything in the chat so far has been seen."""
    mark_read(session, user, member_match(session, user, match_id))
    return Response(status_code=204)


@router.patch("/matches/{match_id}/checklist", response_model=MatchOut)
def patch_checklist(
    match_id: uuid.UUID,
    patch: ChecklistPatch,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    live: Live,
    now: Now,
) -> MatchOut:
    """Tick or untick steps. Either side may; both see the change."""
    match = member_match(session, user, match_id, lock=True)
    if update_checklist(match, patch, now):
        session.commit()
        announce_match_change(session, live, storage, match)
    else:
        session.rollback()
    return _one(session, user, storage, match)


@router.post("/matches/{match_id}/filled", response_model=MatchOut)
def mark_filled(
    match_id: uuid.UUID,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    live: Live,
    now: Now,
) -> MatchOut:
    """Confirm the sublet happened. The lister's confirmation marks the
    listing filled, which takes it out of every deck and off the map. Once
    both have confirmed, each gets a completed sublet on their profile.
    Confirming twice is harmless."""
    match = member_match(session, user, match_id, lock=True)
    if confirm_filled(session, user, match, now):
        session.commit()
        session.refresh(match)
        announce_match_change(session, live, storage, match)
    else:
        session.rollback()
    return _one(session, user, storage, match)
