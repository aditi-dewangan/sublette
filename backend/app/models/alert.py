import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, Identity, Index, String, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

# What an alert is about. See services/alerts.py.
KINDS = ("new_listing", "price_drop", "expiring")
# How often a student wants them: each one as it happens, one bundle a day, or never.
FREQUENCIES = ("instant", "daily", "off")


class Alert(Base):
    """Something worth telling a renter about a listing. Sent at once
    (`instant`) or bundled into the next daily digest (`sent_at` null until
    then). Kept after sending, so the same news isn't sent twice."""

    __tablename__ = "alerts"
    __table_args__ = (Index("ix_alerts_user_id_sent_at", "user_id", "sent_at"),)

    id: Mapped[int] = mapped_column(BigInteger, Identity(always=True), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(20))
    listing_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), index=True
    )
    # For a price drop: {"old_cents": ..., "new_cents": ...}.
    detail: Mapped[dict | None] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
