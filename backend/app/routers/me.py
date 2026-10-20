"""The signed-in user's own account."""

from fastapi import APIRouter, Response
from sqlalchemy import delete, select

from app.config import Settings
from app.deps import AppSettings, CurrentUser, DbSession, Storage
from app.errors import ApiError
from app.models import EmailCode, Listing, ListingPhoto, Upload, User
from app.schemas.errors import FieldError
from app.schemas.user import SchoolOut, UserOut, UserPatch
from app.services.storage import KEY_PATTERN, PhotoStorage, owner_prefix

router = APIRouter(tags=["me"])

# A profile needs these, so once set they can be changed but not emptied.
REQUIRED_ONCE_SET = ("first_name", "year", "program", "smokes", "has_pets")


def user_out(user: User, storage: PhotoStorage, settings: Settings) -> UserOut:
    return UserOut(
        id=user.id,
        email=user.email,
        school=SchoolOut(id=user.school.id, name=user.school.display_name),
        verified=user.verified_at is not None,
        first_name=user.first_name,
        year=user.year,
        program=user.program,
        bio=user.bio,
        photo_url=(storage.public_url(user.photo_key) or None) if user.photo_key else None,
        gender=user.gender,
        smokes=user.smokes,
        has_pets=user.has_pets,
        profile_complete=user.profile_complete,
        completed_sublets=user.completed_sublets,
        terms_version=settings.terms_version,
        terms_accepted=user.terms_version == settings.terms_version,
        created_at=user.created_at,
    )


def _field_error(field: str, message: str) -> ApiError:
    return ApiError(
        422,
        "validation_error",
        "Some fields are missing or invalid.",
        fields=[FieldError(field=field, message=message)],
    )


@router.get("/me", response_model=UserOut)
def read_me(user: CurrentUser, storage: Storage, settings: AppSettings) -> UserOut:
    return user_out(user, storage, settings)


@router.patch("/me", response_model=UserOut)
def update_me(
    patch: UserPatch,
    user: CurrentUser,
    session: DbSession,
    storage: Storage,
    settings: AppSettings,
) -> UserOut:
    """Change any of the profile fields. Fields left out are not touched."""
    changes = patch.model_dump(include=patch.model_fields_set)

    for field in REQUIRED_ONCE_SET:
        if field in changes and changes[field] is None:
            raise _field_error(field, "This can't be empty.")

    old_photo = None
    if "photo_key" in changes:
        key = changes["photo_key"]
        mine = owner_prefix("profile_photo", user.id)
        if key is not None and not (KEY_PATTERN.match(key) and key.startswith(mine)):
            # Only a photo this user uploaded for their own profile can be attached.
            raise _field_error("photo_key", "Upload the photo first, then send its key.")
        if key != user.photo_key:
            old_photo = user.photo_key

    if changes.get("bio") == "":
        changes["bio"] = None
    for field, value in changes.items():
        setattr(user, field, value)
    session.commit()
    session.refresh(user)

    if old_photo:
        storage.delete(old_photo)
    return user_out(user, storage, settings)


@router.delete("/me", status_code=204, response_class=Response)
def delete_me(user: CurrentUser, session: DbSession, storage: Storage) -> Response:
    """Delete the account and everything that belongs to it. Cannot be undone."""
    photos = [user.photo_key] if user.photo_key else []
    photos += session.scalars(
        select(ListingPhoto.key).join(Listing).where(Listing.owner_id == user.id)
    ).all()
    # Photos uploaded but never attached to anything.
    photos += session.scalars(select(Upload.key).where(Upload.user_id == user.id)).all()
    session.execute(delete(EmailCode).where(EmailCode.email == user.email))
    # Listings, photo rows, swipes, matches, messages, blocks and reports about
    # the user go with them (ON DELETE CASCADE). Reports they made stay, with
    # no reporter.
    session.delete(user)
    session.commit()
    for key in set(photos):
        storage.delete(key)
    return Response(status_code=204)
