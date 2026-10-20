"""Receives and serves photos when this server is the photo store.

Mounted when SUBLETTE_STORAGE_BACKEND is `local` (a folder, for development) or
`database` (a table, for $0 staging). With `s3` the phone talks to the store
directly and these routes do not exist.
"""

from fastapi import APIRouter, Request, Response

from app.deps import Now
from app.errors import ApiError
from app.services.storage import KEY_PATTERN, ServerStorage

router = APIRouter(tags=["files"])

NOT_FOUND = ApiError(404, "not_found", "Not Found")


@router.put(ServerStorage.ROUTE + "/{key:path}", status_code=204, response_class=Response)
async def upload(key: str, expires: int, signature: str, request: Request, now: Now) -> Response:
    storage: ServerStorage = request.app.state.storage
    if not KEY_PATTERN.match(key):
        raise NOT_FOUND
    content_type = request.headers.get("content-type", "")
    if not storage.signature_is_valid(key, content_type, expires, signature, now):
        raise ApiError(403, "upload_link_invalid", "This upload link is wrong or has expired.")

    limit = request.app.state.settings.upload_max_bytes
    too_large = ApiError(413, "file_too_large", "That photo is too large.")
    if int(request.headers.get("content-length") or 0) > limit:
        raise too_large
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > limit:
            raise too_large
    if not data:
        raise ApiError(400, "file_empty", "The upload was empty.")

    storage.store.put(key, content_type, bytes(data))
    return Response(status_code=204)


@router.get(ServerStorage.ROUTE + "/{key:path}", response_class=Response)
def read(key: str, request: Request) -> Response:
    storage: ServerStorage = request.app.state.storage
    if not KEY_PATTERN.match(key):
        raise NOT_FOUND
    found = storage.store.get(key)
    if found is None:
        raise NOT_FOUND
    data, content_type = found
    # Keys are never reused, so a photo at a given address never changes.
    return Response(
        content=data,
        media_type=content_type,
        headers={
            "Cache-Control": "public, max-age=31536000, immutable",
            "X-Content-Type-Options": "nosniff",
        },
    )
