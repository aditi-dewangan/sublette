"""Photo storage. The phone uploads straight to storage with a short-lived link.

Four backends, chosen by SUBLETTE_STORAGE_BACKEND:
  local     a folder on this machine, uploaded to and served by this server
            (development)
  database  a table in the database, uploaded to and served by this server
            ($0 staging: Render's free disk is wiped on restart, the database is not)
  s3        any S3-compatible store (production)
  none      uploads are switched off
"""

import hashlib
import hmac
import logging
import os
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Literal, Protocol
from urllib.parse import quote, urlencode

from sqlalchemy import Engine
from sqlalchemy import delete as sql_delete
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.config import Settings

logger = logging.getLogger(__name__)

Purpose = Literal["profile_photo", "listing_photo"]

EXTENSIONS = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/heic": "heic",
    "image/webp": "webp",
}
CONTENT_TYPES = {extension: content_type for content_type, extension in EXTENSIONS.items()}
FOLDERS: dict[str, str] = {"profile_photo": "profiles", "listing_photo": "listings"}

# <folder>/<user id>/<random>.<extension>
KEY_PATTERN = re.compile(
    r"^(profiles|listings)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"/[0-9a-f]{32}\.(jpg|png|heic|webp)$"
)


class StorageUnavailable(Exception):
    """Photo storage is switched off or could not prepare an upload."""


@dataclass(frozen=True)
class PresignedUpload:
    key: str
    upload_url: str
    method: str
    headers: dict[str, str]
    public_url: str
    expires_at: datetime
    max_bytes: int


def new_key(purpose: Purpose, user_id: uuid.UUID, content_type: str) -> str:
    return f"{FOLDERS[purpose]}/{user_id}/{uuid.uuid4().hex}.{EXTENSIONS[content_type]}"


def owner_prefix(purpose: Purpose, user_id: uuid.UUID) -> str:
    """Every key a user may attach to their own profile or listings starts with this."""
    return f"{FOLDERS[purpose]}/{user_id}/"


class PhotoStorage(Protocol):
    def presign_upload(self, key: str, content_type: str, now: datetime) -> PresignedUpload:
        """A link the phone can PUT the photo to. Raises StorageUnavailable."""

    def public_url(self, key: str) -> str:
        """Where the photo can be read once uploaded."""

    def delete(self, key: str) -> None:
        """Remove a photo. Best effort: failures are logged, never raised."""

    def read(self, key: str) -> bytes | None:
        """The photo's bytes, or None if it is missing or can't be read now.
        Used to spot one photo on two listings; never raises."""


class NoStorage:
    def presign_upload(self, key: str, content_type: str, now: datetime) -> PresignedUpload:
        raise StorageUnavailable("storage is switched off")

    def public_url(self, key: str) -> str:
        return ""

    def delete(self, key: str) -> None:
        return None

    def read(self, key: str) -> bytes | None:
        return None


class FileStore(Protocol):
    """Where ServerStorage keeps the bytes."""

    def put(self, key: str, content_type: str, data: bytes) -> None: ...

    def get(self, key: str) -> tuple[bytes, str] | None: ...

    def delete(self, key: str) -> None: ...


class FolderStore:
    """Files in a folder on this machine."""

    def __init__(self, root: str) -> None:
        self.root = Path(root).resolve()

    def path_for(self, key: str) -> Path:
        """The file for a key. Keys are checked against KEY_PATTERN first, so
        they can never point outside the storage folder."""
        if not KEY_PATTERN.match(key):
            raise ValueError("not a storage key")
        return self.root / key

    def put(self, key: str, content_type: str, data: bytes) -> None:
        path = self.path_for(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".part")
        temporary.write_bytes(data)
        os.replace(temporary, path)

    def get(self, key: str) -> tuple[bytes, str] | None:
        path = self.path_for(key)
        if not path.is_file():
            return None
        return path.read_bytes(), CONTENT_TYPES[path.suffix.lstrip(".")]

    def delete(self, key: str) -> None:
        self.path_for(key).unlink(missing_ok=True)


class DatabaseStore:
    """Files in the `stored_files` table. Slower than a real photo store, but
    free and it survives restarts, which Render's free disk does not."""

    def __init__(self, engine: Engine) -> None:
        self._engine = engine

    def put(self, key: str, content_type: str, data: bytes) -> None:
        from app.models import StoredFile

        with Session(self._engine) as session:
            session.merge(StoredFile(key=key, content_type=content_type, data=data, size=len(data)))
            session.commit()

    def get(self, key: str) -> tuple[bytes, str] | None:
        from app.models import StoredFile

        with Session(self._engine) as session:
            row = session.get(StoredFile, key)
            return (row.data, row.content_type) if row else None

    def delete(self, key: str) -> None:
        from app.models import StoredFile

        with Session(self._engine) as session:
            session.execute(sql_delete(StoredFile).where(StoredFile.key == key))
            session.commit()


class ServerStorage:
    """The phone uploads to this server, with a short-lived signed link, and the
    server keeps the photo in a FileStore and serves it back."""

    ROUTE = "/files"

    def __init__(self, settings: Settings, store: FileStore) -> None:
        self._settings = settings
        self.store = store

    def _signature(self, key: str, content_type: str, expires: int) -> str:
        secret = hmac.new(
            self._settings.secret_key.encode(), b"server-storage", hashlib.sha256
        ).digest()
        return hmac.new(secret, f"{key}\n{content_type}\n{expires}".encode(), "sha256").hexdigest()

    def signature_is_valid(
        self, key: str, content_type: str, expires: int, signature: str, now: datetime
    ) -> bool:
        if expires <= now.timestamp():
            return False
        return hmac.compare_digest(signature, self._signature(key, content_type, expires))

    def presign_upload(self, key: str, content_type: str, now: datetime) -> PresignedUpload:
        expires_at = now + timedelta(seconds=self._settings.upload_url_ttl_s)
        expires = int(expires_at.timestamp())
        query = urlencode(
            {"expires": expires, "signature": self._signature(key, content_type, expires)}
        )
        return PresignedUpload(
            key=key,
            upload_url=f"{self._settings.public_base_url}{self.ROUTE}/{key}?{query}",
            method="PUT",
            headers={"Content-Type": content_type},
            public_url=self.public_url(key),
            expires_at=expires_at,
            max_bytes=self._settings.upload_max_bytes,
        )

    def public_url(self, key: str) -> str:
        return f"{self._settings.public_base_url}{self.ROUTE}/{key}"

    def delete(self, key: str) -> None:
        try:
            self.store.delete(key)
        except (OSError, ValueError, SQLAlchemyError) as error:
            logger.warning("Could not delete photo: %s", type(error).__name__)

    def read(self, key: str) -> bytes | None:
        try:
            found = self.store.get(key)
        except (OSError, ValueError, SQLAlchemyError) as error:
            logger.warning("Could not read photo: %s", type(error).__name__)
            return None
        return found[0] if found else None


class S3Storage:
    """Any S3-compatible store: Amazon S3, Cloudflare R2, Backblaze B2 and others."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._client = None

    def _s3(self):
        if self._client is None:
            # Imported here so the server still starts if boto3 is broken or
            # missing; only uploads are affected.
            import boto3
            from botocore.config import Config

            settings = self._settings
            self._client = boto3.client(
                "s3",
                region_name=settings.s3_region,
                endpoint_url=settings.s3_endpoint_url or None,
                aws_access_key_id=settings.s3_access_key_id,
                aws_secret_access_key=settings.s3_secret_access_key,
                config=Config(
                    signature_version="s3v4",
                    connect_timeout=5,
                    read_timeout=10,
                    retries={"max_attempts": 2},
                ),
            )
        return self._client

    def presign_upload(self, key: str, content_type: str, now: datetime) -> PresignedUpload:
        ttl = self._settings.upload_url_ttl_s
        try:
            # Signing happens on this machine; no request is made to the store.
            url = self._s3().generate_presigned_url(
                "put_object",
                Params={
                    "Bucket": self._settings.s3_bucket,
                    "Key": key,
                    "ContentType": content_type,
                },
                ExpiresIn=ttl,
            )
        except Exception as error:
            logger.warning("Could not presign upload: %s", type(error).__name__)
            raise StorageUnavailable(type(error).__name__) from error
        return PresignedUpload(
            key=key,
            upload_url=url,
            method="PUT",
            headers={"Content-Type": content_type},
            public_url=self.public_url(key),
            expires_at=now + timedelta(seconds=ttl),
            max_bytes=self._settings.upload_max_bytes,
        )

    def public_url(self, key: str) -> str:
        return f"{self._settings.s3_public_base_url}/{quote(key)}"

    def delete(self, key: str) -> None:
        try:
            self._s3().delete_object(Bucket=self._settings.s3_bucket, Key=key)
        except Exception as error:
            # The account is still deleted. The orphaned file is logged for cleanup.
            logger.warning("Could not delete photo %s: %s", key, type(error).__name__)

    def read(self, key: str) -> bytes | None:
        try:
            reply = self._s3().get_object(Bucket=self._settings.s3_bucket, Key=key)
            return reply["Body"].read(self._settings.upload_max_bytes + 1)
        except Exception as error:
            logger.warning("Could not read photo %s: %s", key, type(error).__name__)
            return None


def make_storage(settings: Settings, engine: Engine) -> PhotoStorage:
    if settings.storage_backend == "s3":
        return S3Storage(settings)
    if settings.storage_backend == "local":
        return ServerStorage(settings, FolderStore(settings.storage_local_dir))
    if settings.storage_backend == "database":
        return ServerStorage(settings, DatabaseStore(engine))
    return NoStorage()
