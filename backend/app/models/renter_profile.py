import uuid
from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, ForeignKey, Integer, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class RenterProfile(Base):
    """What one student needs when they look for a place: dates, budget,
    preferences and the area on the map. One per user, made on first save.

    The pin (`pin_latitude`, `pin_longitude`, `radius_m`) is private. Only
    GET /v1/me/renter-profile returns it, and only to its owner.
    """

    __tablename__ = "renter_profiles"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    start_date: Mapped[date | None] = mapped_column(Date)
    end_date: Mapped[date | None] = mapped_column(Date)
    # How many days earlier or later than the dates the renter could move.
    flexibility_days: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    max_rent_cents: Mapped[int | None] = mapped_column(Integer)
    # A list of {"field", "value", "importance"}, checked by services/preferences.py.
    preferences: Mapped[list[dict]] = mapped_column(JSONB, default=list, server_default="[]")
    pin_latitude: Mapped[float | None] = mapped_column(Float)
    pin_longitude: Mapped[float | None] = mapped_column(Float)
    radius_m: Mapped[int | None] = mapped_column(Integer)
    # "Tell me when someone lists near my pin" (the empty-deck button).
    notify_new_listings: Mapped[bool] = mapped_column(default=False, server_default="false")

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
