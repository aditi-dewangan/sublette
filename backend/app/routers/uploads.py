"""Short-lived links for uploading photos straight to storage."""

from fastapi import APIRouter

from app.deps import CurrentUser, Now, Storage
from app.errors import ApiError
from app.schemas.uploads import PresignIn, PresignOut
from app.services.storage import StorageUnavailable, new_key

router = APIRouter(prefix="/uploads", tags=["uploads"])


@router.post("/presign", response_model=PresignOut)
def presign(body: PresignIn, user: CurrentUser, storage: Storage, now: Now) -> PresignOut:
    """A link to PUT one profile or listing photo to. The key is under the
    caller's own folder, so nobody can overwrite another user's photo."""
    key = new_key(body.purpose, user.id, body.content_type)
    try:
        upload = storage.presign_upload(key, body.content_type, now)
    except StorageUnavailable as error:
        raise ApiError(
            503,
            "uploads_unavailable",
            "Photo uploads aren't available right now. You can add a photo later.",
        ) from error
    return PresignOut(
        key=upload.key,
        upload_url=upload.upload_url,
        method=upload.method,
        headers=upload.headers,
        public_url=upload.public_url,
        expires_at=upload.expires_at,
        max_bytes=upload.max_bytes,
    )
