"""Six-digit sign-in codes: issuing, hashing and checking."""

import hashlib
import hmac
import secrets
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.config import Settings
from app.errors import ApiError
from app.models import EmailCode


def generate_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def hash_code(settings: Settings, email: str, code: str) -> str:
    """A keyed hash. A six-digit code has only a million values, so a plain
    hash could be reversed by anyone who read the table; this one needs the
    server's secret as well."""
    key = hmac.new(settings.secret_key.encode(), b"email-code", hashlib.sha256).digest()
    return hmac.new(key, f"{email}:{code}".encode(), hashlib.sha256).hexdigest()


def issue_code(session: Session, settings: Settings, email: str, now: datetime) -> str:
    """Replace any earlier code for this email with a new one, and return it.

    The caller emails the code. Only the hash is written to the database.
    """
    code = generate_code()
    values = {
        "code_hash": hash_code(settings, email, code),
        "expires_at": now + timedelta(minutes=settings.code_ttl_minutes),
        "attempts": 0,
        "created_at": now,
    }
    session.execute(
        insert(EmailCode)
        .values(email=email, **values)
        .on_conflict_do_update(index_elements=["email"], set_=values)
    )
    session.flush()
    return code


def check_code(session: Session, settings: Settings, email: str, code: str, now: datetime) -> None:
    """Use up the code for this email, or raise.

    A wrong guess is counted, and the count is written even though this raises.
    After `code_max_attempts` wrong guesses the code is locked: the right code
    stops working too, and the student must request a new one.
    """
    row = session.scalars(
        select(EmailCode).where(EmailCode.email == email).with_for_update()
    ).one_or_none()
    if row is None:
        raise ApiError(400, "code_invalid", "That code isn't right. Check it and try again.")
    if row.attempts >= settings.code_max_attempts:
        raise ApiError(429, "code_locked", "Too many wrong codes. Request a new code.")
    if row.expires_at <= now:
        raise ApiError(400, "code_expired", "That code has expired. Request a new code.")

    if not hmac.compare_digest(row.code_hash, hash_code(settings, email, code)):
        row.attempts += 1
        left = settings.code_max_attempts - row.attempts
        session.flush()
        if left <= 0:
            raise ApiError(429, "code_locked", "Too many wrong codes. Request a new code.")
        tries = "1 try" if left == 1 else f"{left} tries"
        raise ApiError(400, "code_invalid", f"That code isn't right. {tries} left.")

    session.delete(row)
    session.flush()
