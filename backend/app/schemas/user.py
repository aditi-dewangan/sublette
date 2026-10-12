import uuid
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

from app.schemas.common import UtcDateTime

Year = Literal["freshman", "sophomore", "junior", "senior", "graduate", "other"]
Gender = Literal["woman", "man", "nonbinary"]

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
    # True once first name, year, program, smokes and has_pets are all answered.
    profile_complete: bool
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
    # The `key` returned by POST /v1/uploads/presign, after the upload finished.
    photo_key: str | None = Field(default=None, max_length=200)
