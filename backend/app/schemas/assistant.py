from datetime import date
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.schemas.deck import DeckItem
from app.schemas.renter_profile import MAX_RADIUS_M, MIN_RADIUS_M, Preference


class PreferenceChanges(BaseModel):
    """What the assistant understood, in the renter profile's own fields.
    Only what the message asked to change is set; everything else is null
    (dates, budget, area) or left out (preferences)."""

    model_config = ConfigDict(extra="ignore")

    start_date: date | None = None
    end_date: date | None = None
    max_rent_cents: int | None = Field(default=None, gt=0, le=10_000_000)
    radius_m: int | None = Field(default=None, ge=MIN_RADIUS_M, le=MAX_RADIUS_M)
    preferences: list[Preference] = Field(default_factory=list, max_length=20)


class AssistantQueryIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    message: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]


class AssistantItem(BaseModel):
    """A listing card, as in the deck, with why the assistant picked it."""

    item: DeckItem
    why: str


class AssistantAnswer(BaseModel):
    understood: PreferenceChanges
    # The understood changes in one plain line, such as "Private room · under $1,200".
    summary: str
    items: list[AssistantItem]
    # "ai" when a language model ranked and explained; "sublette" when the
    # matching engine did (no model set up, or it failed).
    generated_by: Literal["ai", "sublette"]
    # Shown under the results, always.
    label: str


class AssistantStatus(BaseModel):
    enabled: bool
    label: str
