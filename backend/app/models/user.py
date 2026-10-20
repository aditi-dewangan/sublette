import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.school import School

YEARS = ("freshman", "sophomore", "junior", "senior", "graduate", "other")
GENDERS = ("woman", "man", "nonbinary")
STATUSES = ("active", "suspended")


class User(Base):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    email: Mapped[str] = mapped_column(String(254), unique=True)
    school_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("schools.id"), index=True)
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    first_name: Mapped[str | None] = mapped_column(String(50))
    year: Mapped[str | None] = mapped_column(String(20))
    program: Mapped[str | None] = mapped_column(String(100))
    bio: Mapped[str | None] = mapped_column(String(160))
    # Where the photo sits in storage. The address is worked out when the profile is read.
    photo_key: Mapped[str | None] = mapped_column(String(200))
    # Optional. Only ever used for the gender preference on shared homes.
    gender: Mapped[str | None] = mapped_column(String(20))
    smokes: Mapped[bool | None]
    has_pets: Mapped[bool | None]

    status: Mapped[str] = mapped_column(String(20), default="active", server_default="active")
    # Why the account was suspended, shown to its owner with how to appeal.
    suspended_reason: Mapped[str | None] = mapped_column(String(300))
    suspended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # The version of the terms of service and privacy policy last accepted.
    terms_version: Mapped[str | None] = mapped_column(String(20))
    terms_accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Sublets both sides confirmed as filled through a match. Shown on the profile.
    completed_sublets: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    school: Mapped[School] = relationship(lazy="joined")

    @property
    def profile_complete(self) -> bool:
        """True once the answers every renter and lister must give are in."""
        return (
            bool(self.first_name)
            and bool(self.year)
            and bool(self.program)
            and self.smokes is not None
            and self.has_pets is not None
        )
