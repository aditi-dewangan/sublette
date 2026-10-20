"""Sign-in with a six-digit code emailed to a .edu address.

These three endpoints are the only ones under /v1 that need no account.
"""

import logging
import uuid
from datetime import timedelta

from fastapi import APIRouter
from sqlalchemy import select

from app.deps import AppSettings, ClientIp, DbSession, Mailer, Now, Storage, suspended
from app.errors import ApiError
from app.models import User
from app.routers.me import user_out
from app.schemas.auth import (
    RefreshIn,
    RequestCodeIn,
    RequestCodeOut,
    SessionOut,
    TokensOut,
    VerifyIn,
)
from app.services import analytics, rate_limit
from app.services.codes import check_code, issue_code
from app.services.email_sender import EmailUnavailable
from app.services.emails import domain_of, require_school_email
from app.services.schools import school_for_domain
from app.services.tokens import issue_pair, read_token

logger = logging.getLogger("sublette.auth")

router = APIRouter(prefix="/auth", tags=["auth"])

HOUR = timedelta(hours=1)


@router.post("/request-code", response_model=RequestCodeOut)
def request_code(
    body: RequestCodeIn,
    session: DbSession,
    settings: AppSettings,
    mailer: Mailer,
    now: Now,
    ip: ClientIp,
) -> RequestCodeOut:
    """Email a six-digit code to a .edu address. Works for sign-up and sign-in alike."""
    email = require_school_email(body.email, settings.blocked_domains)

    rate_limit.hit(
        session,
        f"code:ip:{ip}",
        limit=settings.code_requests_per_ip_per_hour,
        window=HOUR,
        now=now,
    )
    rate_limit.hit(
        session,
        f"code:email:{email}",
        limit=settings.code_requests_per_email_per_hour,
        window=HOUR,
        now=now,
    )
    rate_limit.hit(
        session,
        f"code:resend:{email}",
        limit=1,
        window=timedelta(seconds=settings.code_resend_wait_s),
        now=now,
    )

    code = issue_code(session, settings, email, now)
    echo = settings.echo_codes and settings.email_backend != "console"
    if echo:
        # Development: the code is in the terminal whatever the email does.
        logger.warning("Sign-in code for %s: %s  (also emailed)", email, code)
    try:
        mailer.send_code(email, code, settings.code_ttl_minutes)
    except EmailUnavailable as error:
        if echo:
            logger.warning("The email to %s failed (%s). Use the code printed above.", email, error)
            session.commit()
            return RequestCodeOut(
                expires_in=settings.code_ttl_minutes * 60, resend_in=settings.code_resend_wait_s
            )
        # Nothing is kept: no code the student never received, and the failed
        # try does not count against their limit.
        session.rollback()
        raise ApiError(
            503,
            "email_unavailable",
            "We couldn't send your code just now. Try again in a minute.",
            headers={"Retry-After": "60"},
        ) from error
    session.commit()
    return RequestCodeOut(
        expires_in=settings.code_ttl_minutes * 60, resend_in=settings.code_resend_wait_s
    )


@router.post("/verify", response_model=SessionOut)
def verify(
    body: VerifyIn,
    session: DbSession,
    settings: AppSettings,
    storage: Storage,
    now: Now,
    ip: ClientIp,
) -> SessionOut:
    """Check the code. Marks the account verified and returns its tokens."""
    email = require_school_email(body.email, settings.blocked_domains)
    try:
        rate_limit.hit(
            session,
            f"verify:ip:{ip}",
            limit=settings.verify_attempts_per_ip_per_hour,
            window=HOUR,
            now=now,
        )
        check_code(session, settings, email, body.code, now)
    except ApiError:
        # Keep the count of wrong guesses even though the request failed.
        session.commit()
        raise

    user = session.scalars(select(User).where(User.email == email)).one_or_none()
    if user is None:
        school = school_for_domain(session, domain_of(email))
        user = User(id=uuid.uuid4(), email=email, school_id=school.id, status="active")
        session.add(user)
        session.flush()
        analytics.record(session, "signed_up", now, user_id=user.id)
    if user.status != "active":
        session.commit()
        raise suspended(user, settings)
    if user.verified_at is None:
        user.verified_at = now
    session.commit()
    session.refresh(user)

    tokens = issue_pair(settings, user.id, now)
    return SessionOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
        user=user_out(user, storage, settings),
    )


@router.post("/refresh", response_model=TokensOut)
def refresh(body: RefreshIn, session: DbSession, settings: AppSettings, now: Now) -> TokensOut:
    """Trade a refresh token for a new access token and a new refresh token."""
    user_id = read_token(settings, body.refresh_token, "refresh", now)
    user = session.get(User, user_id)
    if user is None or user.verified_at is None:
        raise ApiError(401, "token_invalid", "Please sign in again.")
    if user.status != "active":
        raise suspended(user, settings)
    tokens = issue_pair(settings, user.id, now)
    return TokensOut(
        access_token=tokens.access_token,
        refresh_token=tokens.refresh_token,
        expires_in=tokens.expires_in,
    )
