"""Development only: receives and serves photos when storage is a local folder.

Mounted only when SUBLETTE_STORAGE_BACKEND=local, which production refuses.
In staging and production the phone talks to the S3-compatible store instead.
"""

import os

from fastapi import APIRouter, Request, Response
from fastapi.responses import FileResponse

from app.deps import Now
from app.errors import ApiError
from app.services.storage import CONTENT_TYPES, KEY_PATTERN, LocalStorage

router = APIRouter(tags=["dev storage"])

NOT_FOUND = ApiError(404, "not_found", "Not Found")


@router.put(LocalStorage.ROUTE + "/{key:path}", status_code=204, response_class=Response)
async def upload(key: str, expires: int, signature: str, request: Request, now: Now) -> Response:
    storage: LocalStorage = request.app.state.storage
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

    path = storage.path_for(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".part")
    temporary.write_bytes(bytes(data))
    os.replace(temporary, path)
    return Response(status_code=204)


@router.get(LocalStorage.ROUTE + "/{key:path}", response_class=FileResponse)
def read(key: str, request: Request) -> FileResponse:
    storage: LocalStorage = request.app.state.storage
    if not KEY_PATTERN.match(key):
        raise NOT_FOUND
    path = storage.path_for(key)
    if not path.is_file():
        raise NOT_FOUND
    return FileResponse(path, media_type=CONTENT_TYPES[path.suffix.lstrip(".")])
