"""Reporting, blocking and accepting the terms."""

import uuid

from fastapi import APIRouter, Response
from sqlalchemy import delete, select

from app.deps import AppSettings, CurrentUser, DbSession, Live, Now, Storage
from app.errors import ApiError
from app.models import Block
from app.routers.me import user_out
from app.schemas.safety import BlockedPerson, BlockIn, BlockPage, ReportIn, ReportOut, TermsIn
from app.schemas.user import UserOut
from app.services.safety import block, block_target, report

router = APIRouter(tags=["safety"])


@router.post("/reports", status_code=201, response_model=ReportOut)
def file_report(
    body: ReportIn,
    response: Response,
    user: CurrentUser,
    session: DbSession,
    settings: AppSettings,
    now: Now,
) -> ReportOut:
    """Report a profile, listing or message for review. Reporting the same
    thing again while the first report is open answers 200 with that one."""
    filed, created = report(session, settings, user, body, now)
    if not created:
        response.status_code = 200
    return ReportOut(
        id=filed.id,
        target=filed.target,
        reason=filed.reason,
        status=filed.status,
        created_at=filed.created_at,
    )


@router.post("/blocks", status_code=204, response_class=Response)
def block_person(body: BlockIn, user: CurrentUser, session: DbSession, live: Live, now: Now):
    """Hide this person and the caller from each other everywhere: decks, the
    map, matches and chats. Both apps drop the pair's chats at once."""
    target = block_target(session, user, body)
    for match in block(session, user, target, now):
        for person in (match.renter_id, match.lister_id):
            live.publish(person, {"type": "match_removed", "match_id": str(match.id)})
    return Response(status_code=204)


@router.get("/blocks", response_model=BlockPage)
def list_blocks(user: CurrentUser, session: DbSession, storage: Storage) -> BlockPage:
    rows = session.scalars(
        select(Block).where(Block.blocker_id == user.id).order_by(Block.created_at.desc())
    ).all()
    return BlockPage(
        items=[
            BlockedPerson(
                user_id=row.blocked_id,
                first_name=row.blocked.first_name,
                photo_url=(storage.public_url(row.blocked.photo_key) or None)
                if row.blocked.photo_key
                else None,
                blocked_at=row.created_at,
            )
            for row in rows
        ]
    )


@router.delete("/blocks/{user_id}", status_code=204, response_class=Response)
def unblock(user_id: uuid.UUID, user: CurrentUser, session: DbSession) -> Response:
    """Undo the caller's own block. A block the other person made stays."""
    session.execute(delete(Block).where(Block.blocker_id == user.id, Block.blocked_id == user_id))
    session.commit()
    return Response(status_code=204)


@router.post("/me/terms", response_model=UserOut)
def accept_terms(
    body: TermsIn,
    user: CurrentUser,
    session: DbSession,
    settings: AppSettings,
    storage: Storage,
    now: Now,
) -> UserOut:
    """Record that the student accepted the terms of service and privacy
    policy. Only the current version can be accepted."""
    if body.version != settings.terms_version:
        raise ApiError(
            409, "terms_outdated", "The terms have changed. Read the new version and accept it."
        )
    if user.terms_version != body.version:
        user.terms_version = body.version
        user.terms_accepted_at = now
        session.commit()
        session.refresh(user)
    return user_out(user, storage, settings)
