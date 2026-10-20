import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class AssistantQuery(Base):
    """One question to the assistant and what came of it, for review on the
    admin page. Kept without a name when the account is deleted."""

    __tablename__ = "assistant_queries"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    message: Mapped[str] = mapped_column(String(500))
    # The preference changes it understood, and the listings it returned, in order.
    understood: Mapped[dict] = mapped_column(JSONB)
    listing_ids: Mapped[list] = mapped_column(JSONB)
    backend: Mapped[str] = mapped_column(String(20))
    # True when the language model failed and Sublette's own rules answered.
    fell_back: Mapped[bool] = mapped_column(default=False, server_default="false")
    problem: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), index=True
    )
