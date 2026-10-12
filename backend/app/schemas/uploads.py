from typing import Literal

from pydantic import BaseModel

from app.schemas.common import UtcDateTime


class PresignIn(BaseModel):
    purpose: Literal["profile_photo", "listing_photo"]
    content_type: Literal["image/jpeg", "image/png", "image/heic", "image/webp"]


class PresignOut(BaseModel):
    # Send this back (for example as `photo_key` on PATCH /v1/me) once uploaded.
    key: str
    # PUT the photo's bytes here, with exactly these headers, before `expires_at`.
    upload_url: str
    method: str
    headers: dict[str, str]
    public_url: str
    expires_at: UtcDateTime
    max_bytes: int
