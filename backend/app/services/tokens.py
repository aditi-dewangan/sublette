"""Access and refresh tokens (JWT, HS256)."""

import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Literal

import jwt

from app.config import Settings
from app.errors import ApiError

ALGORITHM = "HS256"
TokenType = Literal["access", "refresh"]


@dataclass(frozen=True)
class TokenPair:
    access_token: str
    refresh_token: str
    expires_in: int  # seconds until the access token expires


def _encode(
    settings: Settings, user_id: uuid.UUID, kind: TokenType, now: datetime, life: timedelta
) -> str:
    claims = {
        "sub": str(user_id),
        "typ": kind,
        "iat": int(now.timestamp()),
        "exp": int((now + life).timestamp()),
        "jti": uuid.uuid4().hex,
    }
    return jwt.encode(claims, settings.secret_key, algorithm=ALGORITHM)


def issue_pair(settings: Settings, user_id: uuid.UUID, now: datetime) -> TokenPair:
    access_life = timedelta(minutes=settings.access_token_minutes)
    return TokenPair(
        access_token=_encode(settings, user_id, "access", now, access_life),
        refresh_token=_encode(
            settings, user_id, "refresh", now, timedelta(days=settings.refresh_token_days)
        ),
        expires_in=int(access_life.total_seconds()),
    )


def read_token(settings: Settings, token: str, kind: TokenType, now: datetime) -> uuid.UUID:
    """The user id inside a token of the expected kind. Raises 401 otherwise."""
    invalid = ApiError(401, "token_invalid", "Please sign in again.")
    try:
        claims = jwt.decode(
            token,
            settings.secret_key,
            algorithms=[ALGORITHM],
            # Times are checked below against `now`, not the machine's clock, so
            # tests can move time and a server whose clock drifts stays consistent.
            options={
                "verify_exp": False,
                "verify_iat": False,
                "require": ["sub", "typ", "exp"],
            },
        )
        user_id = uuid.UUID(claims["sub"])
    except (jwt.InvalidTokenError, ValueError, TypeError) as error:
        raise invalid from error
    if claims.get("typ") != kind:
        raise invalid
    if claims["exp"] <= now.timestamp():
        raise ApiError(401, "token_expired", "Your session has expired. Please sign in again.")
    return user_id
