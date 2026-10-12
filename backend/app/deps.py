"""Things routes ask for: a database session, the clock, the signed-in user."""

from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Annotated

from fastapi import Depends, Request
from sqlalchemy.orm import Session

from app.config import Settings
from app.db import get_session
from app.errors import ApiError
from app.models import User
from app.services.email_sender import EmailSender
from app.services.storage import PhotoStorage
from app.services.tokens import read_token


def get_now() -> datetime:
    """The current time in UTC. Tests replace this to move the clock."""
    return datetime.now(UTC)


def get_app_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_email_sender(request: Request) -> EmailSender:
    return request.app.state.email_sender


def get_storage(request: Request) -> PhotoStorage:
    return request.app.state.storage


def get_client_ip(request: Request) -> str:
    """The caller's address. Behind a hosting platform's proxy this relies on
    uvicorn's --proxy-headers option, which the Dockerfile turns on."""
    return request.client.host if request.client else "unknown"


def _db(request: Request) -> Iterator[Session]:
    yield from get_session(request)


DbSession = Annotated[Session, Depends(_db)]
Now = Annotated[datetime, Depends(get_now)]
AppSettings = Annotated[Settings, Depends(get_app_settings)]
Mailer = Annotated[EmailSender, Depends(get_email_sender)]
Storage = Annotated[PhotoStorage, Depends(get_storage)]
ClientIp = Annotated[str, Depends(get_client_ip)]


def get_current_user(request: Request, session: DbSession, settings: AppSettings, now: Now) -> User:
    """The verified, active account behind the request's access token.

    Every endpoint except sign-in depends on this.
    """
    scheme, _, token = request.headers.get("Authorization", "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise ApiError(
            401,
            "not_signed_in",
            "Please sign in.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    user_id = read_token(settings, token.strip(), "access", now)
    user = session.get(User, user_id)
    if user is None or user.verified_at is None:
        # The account was deleted, or never finished verifying.
        raise ApiError(401, "token_invalid", "Please sign in again.")
    if user.status != "active":
        raise ApiError(
            403,
            "account_suspended",
            "This account has been suspended. Contact support to appeal.",
        )
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]
