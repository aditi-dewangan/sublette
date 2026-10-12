from datetime import datetime

from sqlalchemy import DateTime, Integer, LargeBinary, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class StoredFile(Base):
    """A photo kept in the database, when SUBLETTE_STORAGE_BACKEND=database."""

    __tablename__ = "stored_files"

    key: Mapped[str] = mapped_column(String(200), primary_key=True)
    content_type: Mapped[str] = mapped_column(String(50))
    data: Mapped[bytes] = mapped_column(LargeBinary)
    size: Mapped[int] = mapped_column(Integer)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
