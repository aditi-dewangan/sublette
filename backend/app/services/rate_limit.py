"""Counting actions per bucket in the database. No extra service to run or lose."""

import math
from datetime import datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.errors import ApiError
from app.models import RateLimitHit


def _wait_text(seconds: int) -> str:
    if seconds < 90:
        return f"{seconds} seconds"
    return f"{math.ceil(seconds / 60)} minutes"


def hit(session: Session, bucket: str, *, limit: int, window: timedelta, now: datetime) -> None:
    """Count one action, or raise 429 if `limit` actions already happened in `window`.

    The hit is part of the caller's transaction: it only counts if that commits.
    """
    cutoff = now - window
    session.execute(
        delete(RateLimitHit).where(RateLimitHit.bucket == bucket, RateLimitHit.created_at <= cutoff)
    )
    count, oldest = session.execute(
        select(func.count(), func.min(RateLimitHit.created_at)).where(RateLimitHit.bucket == bucket)
    ).one()
    if count >= limit:
        retry_after = max(1, math.ceil((oldest + window - now).total_seconds()))
        raise ApiError(
            429,
            "rate_limited",
            f"Too many tries. Wait {_wait_text(retry_after)} and try again.",
            headers={"Retry-After": str(retry_after)},
        )
    session.add(RateLimitHit(bucket=bucket, created_at=now))
    session.flush()


def count(session: Session, bucket: str, *, window: timedelta, now: datetime) -> int:
    """How many actions `bucket` has in `window`, without counting a new one."""
    return session.scalar(
        select(func.count()).where(
            RateLimitHit.bucket == bucket, RateLimitHit.created_at > now - window
        )
    )
