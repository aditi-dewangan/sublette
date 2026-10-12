import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


class School(Base):
    """A school. Its name is empty until someone adds one for a new domain."""

    __tablename__ = "schools"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    name: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    domains: Mapped[list["SchoolDomain"]] = relationship(
        back_populates="school", cascade="all, delete-orphan", order_by="SchoolDomain.domain"
    )

    @property
    def display_name(self) -> str:
        """The school's name, or its email domain while it has no name."""
        if self.name:
            return self.name
        return self.domains[0].domain if self.domains else "Unknown school"


class SchoolDomain(Base):
    """An email domain that belongs to a school, such as `uw.edu`."""

    __tablename__ = "school_domains"

    domain: Mapped[str] = mapped_column(String(253), primary_key=True)
    school_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("schools.id", ondelete="CASCADE"), index=True
    )

    school: Mapped[School] = relationship(back_populates="domains")
