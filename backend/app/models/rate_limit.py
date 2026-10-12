from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Index, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class RateLimitHit(Base):
    """One counted action, such as "a code was requested for this email"."""

    __tablename__ = "rate_limit_hits"
    __table_args__ = (Index("ix_rate_limit_hits_bucket_created_at", "bucket", "created_at"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    bucket: Mapped[str] = mapped_column(String(300))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
