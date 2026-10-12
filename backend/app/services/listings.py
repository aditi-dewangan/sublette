"""Rules for listings: what a draft may hold, what publishing requires, who sees what."""

import uuid
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.errors import ApiError
from app.models import Listing, ListingPhoto, User
from app.schemas.errors import FieldError
from app.schemas.listings import ListerOut, ListingFields, ListingOut, PhotoOut
from app.services.geo import offset_point
from app.services.storage import KEY_PATTERN, PhotoStorage, owner_prefix

MIN_PHOTOS = 4

# Fields that always have a value; they can be changed but not cleared.
NOT_NULL = (
    "deposit_cents",
    "utilities_included",
    "furnished",
    "laundry",
    "parking",
    "gender_preference",
    "same_school_only",
    "min_stay_days",
)
DEFAULTS = {
    "deposit_cents": 0,
    "utilities_included": False,
    "furnished": False,
    "laundry": False,
    "parking": False,
    "gender_preference": "any",
    "same_school_only": False,
    "min_stay_days": 0,
}
SHARED_HOMES = ("private_room", "shared_room")


def _invalid(fields: list[FieldError]) -> ApiError:
    return ApiError(422, "validation_error", "Some fields are missing or invalid.", fields=fields)


def not_found() -> ApiError:
    return ApiError(404, "listing_not_found", "That listing isn't available.")


def apply_fields(
    session: Session,
    listing: Listing,
    owner: User,
    fields: ListingFields,
    storage: PhotoStorage,
) -> list[str]:
    """Copy the fields that were sent onto the listing.

    Returns the photo keys no longer used, to delete from storage once the
    change is committed. Raises 422 for anything that is never allowed.
    """
    changes = fields.model_dump(include=fields.model_fields_set)

    empty = [name for name in NOT_NULL if name in changes and changes[name] is None]
    if empty:
        raise _invalid([FieldError(field=name, message="This can't be empty.") for name in empty])

    removed_keys: list[str] = []
    if "photo_keys" in changes:
        keys = changes.pop("photo_keys") or []
        removed_keys = _set_photos(session, listing, owner, keys)

    moved = any(
        name in changes and changes[name] != getattr(listing, name)
        for name in ("latitude", "longitude")
    )
    if "housemates_note" in changes and changes["housemates_note"] == "":
        changes["housemates_note"] = None
    for name, value in changes.items():
        setattr(listing, name, value)

    if moved or (listing.latitude is not None and listing.public_latitude is None):
        if listing.latitude is None or listing.longitude is None:
            listing.public_latitude = listing.public_longitude = None
        else:
            listing.public_latitude, listing.public_longitude = offset_point(
                listing.latitude, listing.longitude
            )

    problems = consistency_problems(listing)
    if problems:
        raise _invalid(problems)
    return removed_keys


def _set_photos(session: Session, listing: Listing, owner: User, keys: list[str]) -> list[str]:
    mine = owner_prefix("listing_photo", owner.id)
    bad = [key for key in keys if not (KEY_PATTERN.match(key) and key.startswith(mine))]
    if bad or len(set(keys)) != len(keys):
        raise _invalid([FieldError(field="photo_keys", message="Upload each photo first.")])
    if keys:
        taken = session.scalars(
            select(ListingPhoto.key).where(
                ListingPhoto.key.in_(keys), ListingPhoto.listing_id != listing.id
            )
        ).all()
        if taken and listing.id is not None:
            raise _invalid(
                [FieldError(field="photo_keys", message="A photo is used by another listing.")]
            )

    current = {photo.key: photo for photo in listing.photos}
    removed = [key for key in current if key not in keys]
    listing.photos = [
        current.get(key) or ListingPhoto(key=key, position=index) for index, key in enumerate(keys)
    ]
    for index, photo in enumerate(listing.photos):
        photo.position = index
    return removed


def consistency_problems(listing: Listing) -> list[FieldError]:
    """Rules that hold for drafts too, whenever both sides are known."""
    problems = []
    if listing.start_date and listing.end_date and listing.end_date <= listing.start_date:
        problems.append(
            FieldError(field="end_date", message="The end date must be after the start date.")
        )
    if listing.gender_preference != "any" and listing.space_type == "entire_unit":
        problems.append(
            FieldError(
                field="gender_preference",
                message="A gender preference can only be set when the renter shares the home.",
            )
        )
    if (
        listing.start_date
        and listing.end_date
        and listing.end_date > listing.start_date
        and listing.min_stay_days > (listing.end_date - listing.start_date).days
    ):
        problems.append(
            FieldError(
                field="min_stay_days",
                message="The minimum stay is longer than the dates you're offering.",
            )
        )
    return problems


def publish_problems(listing: Listing, today: date) -> list[FieldError]:
    """Everything a listing needs before renters can see it."""
    problems = list(consistency_problems(listing))

    def need(condition: bool, field: str, message: str) -> None:
        if not condition:
            problems.append(FieldError(field=field, message=message))

    need(len(listing.photos) >= MIN_PHOTOS, "photo_keys", f"Add at least {MIN_PHOTOS} photos.")
    need(bool(listing.address), "address", "Enter the address.")
    need(
        listing.latitude is not None and listing.longitude is not None,
        "latitude",
        "Confirm the address on the map.",
    )
    need(listing.rent_cents is not None, "rent_cents", "Enter the monthly rent.")
    need(listing.start_date is not None, "start_date", "Choose the move-in date.")
    need(listing.end_date is not None, "end_date", "Choose the move-out date.")
    if listing.end_date is not None and listing.end_date < today:
        problems.append(FieldError(field="end_date", message="The move-out date has passed."))
    need(listing.space_type is not None, "space_type", "Choose the type of space.")
    need(listing.bedrooms is not None, "bedrooms", "Enter the number of bedrooms.")
    need(listing.bathroom is not None, "bathroom", "Choose a private or shared bathroom.")
    need(
        listing.housemates_staying is not None,
        "housemates_staying",
        "Say how many housemates are staying.",
    )
    need(listing.pets_allowed is not None, "pets_allowed", "Say whether pets are welcome.")
    need(listing.smoking_allowed is not None, "smoking_allowed", "Say whether smokers are welcome.")
    need(
        listing.landlord_consent is not None,
        "landlord_consent",
        "Say whether your landlord has approved subletting.",
    )
    return problems


def require_publishable(listing: Listing, today: date) -> None:
    problems = publish_problems(listing, today)
    if problems:
        raise ApiError(
            422,
            "listing_incomplete",
            "Finish the listing before publishing it.",
            fields=problems,
        )


def new_listing(owner: User) -> Listing:
    return Listing(id=uuid.uuid4(), owner_id=owner.id, owner=owner, status="draft", **DEFAULTS)


def listing_out(listing: Listing, viewer: User, storage: PhotoStorage) -> ListingOut:
    owner = listing.owner
    is_owner = viewer.id == listing.owner_id

    def url(key: str | None) -> str | None:
        return (storage.public_url(key) or None) if key else None

    return ListingOut(
        id=listing.id,
        status=listing.status,
        is_owner=is_owner,
        address=listing.address if is_owner else None,
        latitude=listing.latitude if is_owner else None,
        longitude=listing.longitude if is_owner else None,
        public_latitude=listing.public_latitude,
        public_longitude=listing.public_longitude,
        rent_cents=listing.rent_cents,
        deposit_cents=listing.deposit_cents,
        utilities_included=listing.utilities_included,
        start_date=listing.start_date,
        end_date=listing.end_date,
        space_type=listing.space_type,
        bedrooms=listing.bedrooms,
        bathroom=listing.bathroom,
        furnished=listing.furnished,
        laundry=listing.laundry,
        parking=listing.parking,
        housemates_staying=listing.housemates_staying,
        housemates_note=listing.housemates_note,
        pets_allowed=listing.pets_allowed,
        smoking_allowed=listing.smoking_allowed,
        gender_preference=listing.gender_preference,
        same_school_only=listing.same_school_only,
        min_stay_days=listing.min_stay_days,
        landlord_consent=listing.landlord_consent,
        photos=[PhotoOut(key=photo.key, url=url(photo.key)) for photo in listing.photos],
        lister=ListerOut(
            first_name=owner.first_name,
            photo_url=url(owner.photo_key),
            school_name=owner.school.display_name,
            verified=owner.verified_at is not None,
        ),
        created_at=listing.created_at,
        published_at=listing.published_at,
    )
