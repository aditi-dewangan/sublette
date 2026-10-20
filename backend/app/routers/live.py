"""GET /v1/ws: live events for a phone with the app open.

Sign in with the same `Authorization: Bearer <access token>` header as every
other request. The server sends JSON events and ignores anything the phone
sends:

  {"type": "ready"}                                  once, when subscribed
  {"type": "message", "message": {...}, "match": {...}}
  {"type": "match", "new_match": true|false, "match": {...}}

It closes the socket with
  4401 when the token is missing, invalid or expires: refresh it, reconnect;
  4403 when the account is suspended, at once if it happens while
       connected: don't reconnect;
  1013 when the phone falls too far behind: reconnect and reload.
"""

import asyncio
import contextlib
import uuid

from fastapi import APIRouter, WebSocket
from sqlalchemy import Engine, select
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from app.deps import Now
from app.errors import ApiError
from app.models import User
from app.services.live import CLOSE_NOT_SIGNED_IN, CLOSE_SUSPENDED, Connection
from app.services.tokens import read_token_until

router = APIRouter(tags=["live"])

CLOSE_TOO_SLOW = 1013


def _account_status(engine: Engine, user_id: uuid.UUID) -> str | None:
    with Session(engine) as session:
        row = session.execute(
            select(User.status, User.verified_at).where(User.id == user_id)
        ).one_or_none()
    if row is None or row.verified_at is None:
        return None
    return row.status


@router.websocket("/ws")
async def live_events(websocket: WebSocket, now: Now) -> None:
    await websocket.accept()
    app = websocket.app
    scheme, _, token = websocket.headers.get("authorization", "").partition(" ")
    try:
        if scheme.lower() != "bearer" or not token.strip():
            raise ApiError(401, "not_signed_in", "Please sign in.")
        user_id, expires = read_token_until(app.state.settings, token.strip(), "access", now)
    except ApiError as error:
        await websocket.close(code=CLOSE_NOT_SIGNED_IN, reason=error.code)
        return

    status = await run_in_threadpool(_account_status, app.state.engine, user_id)
    if status is None:
        await websocket.close(code=CLOSE_NOT_SIGNED_IN, reason="token_invalid")
        return
    if status != "active":
        await websocket.close(code=CLOSE_SUSPENDED, reason="account_suspended")
        return

    connection = app.state.live.connect(user_id)
    try:
        # A suspension between the check above and connect() found no socket
        # to close; look once more now that this one is registered.
        if await run_in_threadpool(_account_status, app.state.engine, user_id) != "active":
            await websocket.close(code=CLOSE_SUSPENDED, reason="account_suspended")
            return
        await websocket.send_json({"type": "ready"})
        await _relay(websocket, connection, expires - now.timestamp())
    finally:
        app.state.live.disconnect(connection)


async def _relay(websocket: WebSocket, connection: Connection, seconds: float) -> None:
    """Send events until the phone leaves, falls behind, or the token expires."""

    async def send() -> None:
        while True:
            await websocket.send_json(await connection.events.get())

    async def receive() -> None:
        while (await websocket.receive())["type"] != "websocket.disconnect":
            pass

    sender = asyncio.create_task(send())
    receiver = asyncio.create_task(receive())
    overflow = asyncio.create_task(connection.overflowed.wait())
    suspended = asyncio.create_task(connection.suspended.wait())
    done, pending = await asyncio.wait(
        {sender, receiver, overflow, suspended},
        timeout=max(seconds, 0),
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
    if receiver in done or sender in done:
        return  # the phone went away
    if suspended in done:
        code, reason = CLOSE_SUSPENDED, "account_suspended"
    elif overflow in done:
        code, reason = CLOSE_TOO_SLOW, "too_slow"
    else:
        code, reason = CLOSE_NOT_SIGNED_IN, "token_expired"
    # The phone may have closed it at the same moment.
    with contextlib.suppress(RuntimeError):
        await websocket.close(code=code, reason=reason)
