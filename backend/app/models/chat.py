import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, Identity, Index, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Message(Base):
    """One chat message between the two sides of a match.

    `client_id` is the id the app made up for the message, so a message resent
    after a lost answer is stored once. `seq` orders messages: two sent in the
    same second still have an order, and "read up to" is a number.
    """

    __tablename__ = "messages"
    __table_args__ = (Index("ix_messages_match_id_seq", "match_id", "seq"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    seq: Mapped[int] = mapped_column(BigInteger, Identity(always=True), unique=True)
    client_id: Mapped[uuid.UUID | None] = mapped_column(unique=True)
    match_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("matches.id", ondelete="CASCADE"))
    sender_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    body: Mapped[str] = mapped_column(String(2000))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


ENVIRONMENTS = ("sandbox", "production")


class DeviceToken(Base):
    """A phone that can receive push notifications for one account.

    The token belongs to one phone, so signing in as someone else on the same
    phone moves it to that account.
    """

    __tablename__ = "device_tokens"

    token: Mapped[str] = mapped_column(String(200), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    # Which Apple push server the token belongs to: Debug builds use sandbox.
    environment: Mapped[str] = mapped_column(String(20))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
