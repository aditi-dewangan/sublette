import uuid
from typing import Annotated, Literal, Self

from pydantic import BaseModel, ConfigDict, StringConstraints, model_validator

from app.schemas.common import UtcDateTime

ReportTarget = Literal["user", "listing", "message"]
ReportReason = Literal[
    "scam", "harassment", "inappropriate", "fake", "discrimination", "unsafe", "other"
]
Details = Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)]


class ReportIn(BaseModel):
    """Report a profile (`user`), a listing or a message, by its id."""

    model_config = ConfigDict(extra="forbid")

    target: ReportTarget
    id: uuid.UUID
    reason: ReportReason
    # Anything else the reviewer should know. Optional.
    details: Details | None = None


class ReportOut(BaseModel):
    id: uuid.UUID
    target: ReportTarget
    reason: ReportReason
    # open, dismissed or actioned. The app only shows that it was received.
    status: Literal["open", "dismissed", "actioned"]
    created_at: UtcDateTime


class BlockIn(BaseModel):
    """The person to block: by their id, or as the lister of a listing."""

    model_config = ConfigDict(extra="forbid")

    user_id: uuid.UUID | None = None
    listing_id: uuid.UUID | None = None

    @model_validator(mode="after")
    def _exactly_one(self) -> Self:
        if (self.user_id is None) == (self.listing_id is None):
            raise ValueError("Send user_id or listing_id, not both.")
        return self


class BlockedPerson(BaseModel):
    user_id: uuid.UUID
    first_name: str | None
    photo_url: str | None
    blocked_at: UtcDateTime


class BlockPage(BaseModel):
    """The people the caller blocked, newest first."""

    items: list[BlockedPerson]


class TermsIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # The `terms_version` from GET /v1/me that the student was shown.
    version: Annotated[str, StringConstraints(min_length=1, max_length=20)]
