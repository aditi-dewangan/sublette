from datetime import date
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt

from app.schemas.common import UtcDateTime

PreferenceField = Literal[
    "space_type",
    "private_bathroom",
    "furnished",
    "laundry",
    "parking",
    "pet_free",
    "smoke_free",
    "housemate_count",
    "housemate_gender",
]
Importance = Literal["must", "nice", "off"]

# Smallest and largest search area, in meters around the pin.
MIN_RADIUS_M = 500
MAX_RADIUS_M = 50_000


class Preference(BaseModel):
    """One preference. `value` depends on `field`:

    * space_type: a list such as ["private_room", "entire_unit"]
    * private_bathroom, furnished, laundry, parking, pet_free, smoke_free: true
    * housemate_count: the most housemates the renter would live with, 0 to 10
    * housemate_gender: "women" or "men" (no preference is importance "off")
    """

    model_config = ConfigDict(extra="forbid")

    field: PreferenceField
    value: StrictBool | StrictInt | str | list[str]
    importance: Importance


class Pin(BaseModel):
    """The middle of the area the renter wants to live in. Private to its owner."""

    model_config = ConfigDict(extra="forbid")

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_m: int = Field(ge=MIN_RADIUS_M, le=MAX_RADIUS_M)


class RenterProfileIn(BaseModel):
    """The whole renter profile. PUT replaces it: anything left out is cleared."""

    model_config = ConfigDict(extra="forbid")

    start_date: date | None = None
    end_date: date | None = None
    flexibility_days: int = Field(default=0, ge=0, le=60)
    max_rent_cents: int | None = Field(default=None, gt=0, le=10_000_000)
    preferences: list[Preference] = Field(default_factory=list, max_length=20)
    pin: Pin | None = None


class RenterProfileOut(BaseModel):
    start_date: date | None
    end_date: date | None
    flexibility_days: int
    max_rent_cents: int | None
    preferences: list[Preference]
    pin: Pin | None
    # True once dates, budget and pin are set: enough to build a deck.
    complete: bool
    # Null until the renter saves for the first time.
    updated_at: UtcDateTime | None
