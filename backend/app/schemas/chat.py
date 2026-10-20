import uuid
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.schemas.common import UtcDateTime


class MessageIn(BaseModel):
    """A chat message. `message_id` is an id the app makes up, so a message
    sent twice (a retry after a lost answer) is stored once."""

    model_config = ConfigDict(extra="forbid")

    body: str = Field(min_length=1, max_length=2000)
    message_id: uuid.UUID | None = None


class MessageOut(BaseModel):
    id: uuid.UUID
    # The app's own id for this message, when it sent one.
    message_id: uuid.UUID | None
    match_id: uuid.UUID
    sender_id: uuid.UUID
    # True when the caller sent it.
    mine: bool
    body: str
    created_at: UtcDateTime


class MessagePage(BaseModel):
    """Oldest first. `has_more` is true when older messages exist: ask again
    with `before` set to the first id here."""

    items: list[MessageOut]
    has_more: bool


class Checklist(BaseModel):
    """The steps to a sublet, shared by both sides of a match."""

    tour_done: bool
    landlord_consent_confirmed: bool
    dates_agreed: bool
    sublease_signed: bool
    updated_at: UtcDateTime | None


class ChecklistPatch(BaseModel):
    """Send only the steps that changed."""

    model_config = ConfigDict(extra="forbid")

    tour_done: bool | None = None
    landlord_consent_confirmed: bool | None = None
    dates_agreed: bool | None = None
    sublease_signed: bool | None = None


class Filled(BaseModel):
    """Each side's "Filled" confirmation. The lister's marks the listing
    filled; once both confirm, each gets a completed sublet on their profile."""

    renter_confirmed: bool
    lister_confirmed: bool
    completed: bool


class DeviceIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # The token Apple gave the phone, as hex.
    token: str = Field(min_length=16, max_length=200, pattern=r"^[0-9a-fA-F]+$")
    # Debug builds talk to Apple's sandbox push server. "simulator" is a
    # simulator's own id, for a local server to push into with simctl.
    environment: Literal["sandbox", "production", "simulator"]
