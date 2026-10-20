import secrets
import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Float, ForeignKey, Identity, Index, String, Text, func
from sqlalchemy import text as sql
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

# Recorded at most once per account, and once per listing (see services/analytics.py).
ONCE_PER_USER = ("signed_up", "profile_completed", "first_swipe", "first_match")
ONCE_PER_LISTING = ("listing_published", "listing_first_match", "listing_filled")
# Sent by the app.
FROM_THE_APP = ("app_opened", "feature_used")

# No 0/O or 1/I/L, so a code read aloud or off a poster is typed right.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 7


def new_referral_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def _names(names: tuple[str, ...]) -> str:
    return "name IN (" + ", ".join(f"'{name}'" for name in names) + ")"


class Event(Base):
    """One step in the funnel or one use of a feature. Kept without a name
    when the account is deleted (`user_id` becomes null), so totals stay
    right; nothing in it identifies anyone."""

    __tablename__ = "events"
    __table_args__ = (
        Index("ix_events_name_created_at", "name", "created_at"),
        Index(
            "uq_events_once_per_user",
            "user_id",
            "name",
            unique=True,
            postgresql_where=sql(_names(ONCE_PER_USER)),
        ),
        Index(
            "uq_events_once_per_listing",
            "listing_id",
            "name",
            unique=True,
            postgresql_where=sql(_names(ONCE_PER_LISTING)),
        ),
    )

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    name: Mapped[str] = mapped_column(String(40))
    user_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    listing_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("listings.id", ondelete="SET NULL"), index=True
    )
    # Which feature, for "feature_used".
    detail: Mapped[str | None] = mapped_column(String(40))
    # Days from publishing, for "listing_first_match" and "listing_filled".
    value: Mapped[float | None] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class CrashReport(Base):
    """A crash or hang the phone reported (Apple's MetricKit), sent on the
    next launch."""

    __tablename__ = "crash_reports"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    kind: Mapped[str] = mapped_column(String(20))
    app_version: Mapped[str] = mapped_column(String(20))
    os_version: Mapped[str] = mapped_column(String(40))
    payload: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
