"""Phones that receive push notifications."""

from fastapi import APIRouter, Response
from sqlalchemy import delete
from sqlalchemy.dialects.postgresql import insert

from app.deps import CurrentUser, DbSession, Now
from app.models import DeviceToken
from app.schemas.chat import DeviceIn

router = APIRouter(tags=["devices"])


@router.post("/devices", status_code=204, response_class=Response)
def register_device(body: DeviceIn, user: CurrentUser, session: DbSession, now: Now) -> Response:
    """This phone may receive pushes for the signed-in account. Sending the
    same token again is fine; a token another account had moves to this one
    (the same phone, signed in as someone else)."""
    token = body.token.lower()
    session.execute(
        insert(DeviceToken)
        .values(token=token, user_id=user.id, environment=body.environment, updated_at=now)
        .on_conflict_do_update(
            index_elements=["token"],
            set_={"user_id": user.id, "environment": body.environment, "updated_at": now},
        )
    )
    session.commit()
    return Response(status_code=204)


@router.delete("/devices/{token}", status_code=204, response_class=Response)
def unregister_device(token: str, user: CurrentUser, session: DbSession) -> Response:
    """Stop pushes to this phone, as when signing out. Someone else's token,
    or one already gone, is left alone and still answers 204."""
    session.execute(
        delete(DeviceToken).where(
            DeviceToken.token == token.lower(), DeviceToken.user_id == user.id
        )
    )
    session.commit()
    return Response(status_code=204)
