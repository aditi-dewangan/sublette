import uuid
from datetime import date
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.schemas.common import UtcDateTime

SpaceType = Literal["entire_unit", "private_room", "shared_room"]
Bathroom = Literal["private", "shared"]
GenderPreference = Literal["any", "women", "men"]
# Who lives in the home now: the housemates who are staying.
HouseholdGender = Literal["women", "men", "mixed"]
# "expired": the move-in date passed without a renewal. "removed": taken
# down by Sublette after a review.
Status = Literal["draft", "active", "paused", "filled", "expired", "removed"]

Address = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=300)]
Note = Annotated[str, StringConstraints(strip_whitespace=True, max_length=140)]

MAX_PHOTOS = 12


class ListingFields(BaseModel):
    """Every answer a lister gives. All optional: a draft may be incomplete.

    On PATCH, a field left out is unchanged and a field sent as null is cleared.
    """

    model_config = ConfigDict(extra="forbid")

    address: Address | None = None
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    rent_cents: int | None = Field(default=None, gt=0, le=10_000_000)
    deposit_cents: int | None = Field(default=None, ge=0, le=10_000_000)
    utilities_included: bool | None = None
    start_date: date | None = None
    end_date: date | None = None
    space_type: SpaceType | None = None
    bedrooms: int | None = Field(default=None, ge=0, le=20)
    bathroom: Bathroom | None = None
    furnished: bool | None = None
    laundry: bool | None = None
    parking: bool | None = None
    housemates_staying: int | None = Field(default=None, ge=0, le=20)
    housemates_note: Note | None = None
    pets_allowed: bool | None = None
    smoking_allowed: bool | None = None
    household_gender: HouseholdGender | None = None
    gender_preference: GenderPreference | None = None
    same_school_only: bool | None = None
    min_stay_days: int | None = Field(default=None, ge=0, le=730)
    landlord_consent: bool | None = None
    # Keys returned by POST /v1/uploads/presign (purpose listing_photo), in display order.
    photo_keys: list[str] | None = Field(default=None, max_length=MAX_PHOTOS)


class StatusChange(BaseModel):
    status: Literal["active", "paused", "filled"]


class PhotoOut(BaseModel):
    key: str
    url: str | None


class ListerOut(BaseModel):
    """What renters see about the person offering the place."""

    first_name: str | None
    photo_url: str | None
    school_name: str
    verified: bool


class ListingOut(BaseModel):
    id: uuid.UUID
    status: Status
    # True when the caller owns this listing.
    is_owner: bool
    # True when the caller is a renter who matched with this listing.
    is_matched: bool
    # Exact location: only for the owner and a matched renter. Null for everyone else.
    address: str | None
    latitude: float | None
    longitude: float | None
    # About 150 meters from the real address, the same point every time.
    public_latitude: float | None
    public_longitude: float | None
    rent_cents: int | None
    deposit_cents: int
    utilities_included: bool
    start_date: date | None
    end_date: date | None
    space_type: SpaceType | None
    bedrooms: int | None
    bathroom: Bathroom | None
    furnished: bool
    laundry: bool
    parking: bool
    housemates_staying: int | None
    housemates_note: str | None
    pets_allowed: bool | None
    smoking_allowed: bool | None
    # Women, men or mixed. Null when no housemates are staying.
    household_gender: HouseholdGender | None
    gender_preference: GenderPreference
    same_school_only: bool
    min_stay_days: int
    landlord_consent: bool | None
    photos: list[PhotoOut]
    lister: ListerOut
    created_at: UtcDateTime
    published_at: UtcDateTime | None
    # Owner only: the last day it stays live unless renewed (publish it again).
    expires_on: date | None
    # Owner only: why Sublette removed it.
    removed_reason: str | None


class ListingPage(BaseModel):
    items: list[ListingOut]
    # Pass as `cursor` to get the next page. Null on the last page.
    next_cursor: str | None
