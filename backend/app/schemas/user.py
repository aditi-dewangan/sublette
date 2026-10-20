import uuid
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.schemas.common import HomeVibe, HowOften, SleepSchedule, Tidiness, UtcDateTime

Year = Literal["freshman", "sophomore", "junior", "senior", "graduate", "other"]
Gender = Literal["woman", "man", "nonbinary"]
AlertFrequency = Literal["instant", "daily", "off"]

FirstName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50)]
Program = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]
Bio = Annotated[str, StringConstraints(strip_whitespace=True, max_length=160)]


class SchoolOut(BaseModel):
    id: uuid.UUID
    # The school's name, or its email domain while nobody has named it yet.
    name: str


class UserOut(BaseModel):
    """A user's own profile, as returned to that user."""

    id: uuid.UUID
    email: str
    school: SchoolOut
    verified: bool
    first_name: str | None
    year: Year | None
    program: str | None
    bio: str | None
    photo_url: str | None
    gender: Gender | None
    smokes: bool | None
    has_pets: bool | None
    # Lifestyle, all optional (services/lifestyle.py).
    sleep_schedule: SleepSchedule | None
    tidiness: Tidiness | None
    guests: HowOften | None
    home_daytime: HowOften | None
    home_vibe: HomeVibe | None
    # True once first name, year, program, smokes and has_pets are all answered.
    profile_complete: bool
    # Sublets finished through Sublette: both sides confirmed "Filled".
    completed_sublets: int
    # The current terms of service and privacy policy, and whether this
    # account accepted them. Accept with POST /v1/me/terms.
    terms_version: str
    terms_accepted: bool
    # This account's code to give friends, and whether it used someone's.
    referral_code: str
    referred: bool
    # How often alerts come: instant, daily (one digest a day) or off.
    alert_frequency: AlertFrequency
    created_at: UtcDateTime


class UserPatch(BaseModel):
    """Fields a user may change. Leave a field out to keep it as it is."""

    model_config = ConfigDict(extra="forbid")

    first_name: FirstName | None = None
    year: Year | None = None
    program: Program | None = None
    bio: Bio | None = None
    gender: Gender | None = None
    smokes: bool | None = None
    has_pets: bool | None = None
    alert_frequency: AlertFrequency | None = None
    # Lifestyle, all optional (services/lifestyle.py).
    sleep_schedule: SleepSchedule | None = None
    tidiness: Tidiness | None = None
    guests: HowOften | None = None
    home_daytime: HowOften | None = None
    home_vibe: HomeVibe | None = None
    # The `key` returned by POST /v1/uploads/presign, after the upload finished.
    photo_key: str | None = Field(default=None, max_length=200)
