import uuid
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Index, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.user import User

SOURCES = ("user", "automatic")
TARGETS = ("user", "listing", "message")
# What a student can report something for.
USER_REASONS = (
    "scam",
    "harassment",
    "inappropriate",
    "fake",
    "discrimination",
    "unsafe",
    "other",
)
# What the server flags on its own.
AUTOMATIC_REASONS = ("payment_request", "outside_link", "duplicate_photo")
REPORT_STATUSES = ("open", "dismissed", "actioned")


class Report(Base):
    """Something sent to the review queue: a student's report, or a scam flag
    the server raised on its own (`source` "automatic", no reporter).

    `subject_id` is the person responsible: the one reported, the lister of a
    reported listing, or the sender of a reported message. `excerpt` keeps what
    was reported as it was then, so an edit can't hide it from review.
    """

    __tablename__ = "reports"
    __table_args__ = (Index("ix_reports_status_created_at", "status", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    source: Mapped[str] = mapped_column(String(20))
    # Kept when the reporter deletes their account; the report still matters.
    reporter_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"), index=True
    )
    subject_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    target: Mapped[str] = mapped_column(String(20))
    listing_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), index=True
    )
    message_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("messages.id", ondelete="CASCADE"), index=True
    )
    reason: Mapped[str] = mapped_column(String(30))
    details: Mapped[str | None] = mapped_column(String(500))
    excerpt: Mapped[str | None] = mapped_column(String(2000))
    status: Mapped[str] = mapped_column(String(20), default="open", server_default="open")
    resolution: Mapped[str | None] = mapped_column(String(300))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    reporter: Mapped[User | None] = relationship(foreign_keys=[reporter_id], lazy="joined")
    subject: Mapped[User] = relationship(foreign_keys=[subject_id], lazy="joined")


class Block(Base):
    """`blocker` blocked `blocked`. Either way round, the two are hidden from
    each other everywhere: decks, the map, matches and chats."""

    __tablename__ = "blocks"
    __table_args__ = (CheckConstraint("blocker_id <> blocked_id", name="not_self"),)

    blocker_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    blocked_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    blocked: Mapped[User] = relationship(foreign_keys=[blocked_id], lazy="joined")


class Upload(Base):
    """A photo key handed out for upload. Keys never attached to a profile or
    listing are deleted from storage after a day (services/housekeeping.py)."""

    __tablename__ = "uploads"

    key: Mapped[str] = mapped_column(String(200), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
