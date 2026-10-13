import uuid
from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, ForeignKey, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.user import User

STATUSES = ("draft", "active", "paused", "filled", "expired")
SPACE_TYPES = ("entire_unit", "private_room", "shared_room")
BATHROOMS = ("private", "shared")
GENDER_PREFERENCES = ("any", "women", "men")
HOUSEHOLD_GENDERS = ("women", "men", "mixed")


class Listing(Base):
    """A room or unit a student wants someone to take over.

    A draft may be incomplete. Publishing checks every required answer.
    `latitude`/`longitude` are exact and shown only to the owner (and, from
    phase 6, to matched renters). Everyone else gets `public_latitude` and
    `public_longitude`, a fixed point about 150 meters away.
    """

    __tablename__ = "listings"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    status: Mapped[str] = mapped_column(String(20), default="draft", server_default="draft")

    address: Mapped[str | None] = mapped_column(String(300))
    latitude: Mapped[float | None] = mapped_column(Float)
    longitude: Mapped[float | None] = mapped_column(Float)
    public_latitude: Mapped[float | None] = mapped_column(Float)
    public_longitude: Mapped[float | None] = mapped_column(Float)

    rent_cents: Mapped[int | None] = mapped_column(Integer)
    deposit_cents: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    utilities_included: Mapped[bool] = mapped_column(default=False, server_default="false")
    start_date: Mapped[date | None] = mapped_column(Date)
    end_date: Mapped[date | None] = mapped_column(Date)

    space_type: Mapped[str | None] = mapped_column(String(20))
    bedrooms: Mapped[int | None] = mapped_column(Integer)
    bathroom: Mapped[str | None] = mapped_column(String(10))
    furnished: Mapped[bool] = mapped_column(default=False, server_default="false")
    laundry: Mapped[bool] = mapped_column(default=False, server_default="false")
    parking: Mapped[bool] = mapped_column(default=False, server_default="false")

    housemates_staying: Mapped[int | None] = mapped_column(Integer)
    housemates_note: Mapped[str | None] = mapped_column(String(140))
    pets_allowed: Mapped[bool | None]
    smoking_allowed: Mapped[bool | None]
    # Who the renter would live with: the housemates staying. Needed to publish
    # when anyone stays; cleared when nobody does.
    household_gender: Mapped[str | None] = mapped_column(String(10))

    gender_preference: Mapped[str] = mapped_column(String(10), default="any", server_default="any")
    same_school_only: Mapped[bool] = mapped_column(default=False, server_default="false")
    min_stay_days: Mapped[int] = mapped_column(Integer, default=0, server_default="0")
    landlord_consent: Mapped[bool | None]

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    owner: Mapped[User] = relationship(lazy="joined")
    photos: Mapped[list["ListingPhoto"]] = relationship(
        back_populates="listing",
        cascade="all, delete-orphan",
        order_by="ListingPhoto.position",
        lazy="selectin",
    )


class ListingPhoto(Base):
    __tablename__ = "listing_photos"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    listing_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), index=True
    )
    key: Mapped[str] = mapped_column(String(200), unique=True)
    position: Mapped[int] = mapped_column(Integer)

    listing: Mapped[Listing] = relationship(back_populates="photos")
