import uuid
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.listing import Listing
from app.models.user import User

SIDES = ("renter", "lister")
ACTIONS = ("like", "pass")


class Swipe(Base):
    """One like or pass.

    side "renter": the renter (`renter_id`, also `swiper_id`) swiped on a listing.
    side "lister": the listing's owner (`swiper_id`) swiped on a renter who liked it.

    One swipe per side, listing and renter, so sending the same swipe again
    changes nothing. `client_id` is the id the app made up for the swipe, so a
    swipe resent after a lost answer is recognised.
    """

    __tablename__ = "swipes"
    __table_args__ = (UniqueConstraint("side", "listing_id", "renter_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    client_id: Mapped[uuid.UUID | None] = mapped_column(unique=True)
    side: Mapped[str] = mapped_column(String(10))
    action: Mapped[str] = mapped_column(String(10))
    listing_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), index=True
    )
    renter_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    swiper_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class Match(Base):
    """A renter liked a listing and its lister liked them back. One per pair."""

    __tablename__ = "matches"
    __table_args__ = (UniqueConstraint("listing_id", "renter_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    listing_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), index=True
    )
    renter_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    lister_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    listing: Mapped[Listing] = relationship(lazy="joined")
    renter: Mapped[User] = relationship(foreign_keys=[renter_id], lazy="joined")
    lister: Mapped[User] = relationship(foreign_keys=[lister_id], lazy="joined")


class SavedListing(Base):
    """A listing the renter put aside for later. It leaves the deck until unsaved."""

    __tablename__ = "saved_listings"

    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    listing_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("listings.id", ondelete="CASCADE"), primary_key=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    listing: Mapped[Listing] = relationship(lazy="joined")
