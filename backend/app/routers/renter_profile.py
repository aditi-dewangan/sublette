"""Renter mode: what the signed-in student is looking for."""

from fastapi import APIRouter

from app.deps import CurrentUser, DbSession
from app.errors import ApiError
from app.models import RenterProfile
from app.schemas.errors import FieldError
from app.schemas.renter_profile import Pin, Preference, RenterProfileIn, RenterProfileOut
from app.services.preferences import preference_problems

router = APIRouter(tags=["renter"])


def is_complete(profile: RenterProfile | None) -> bool:
    return bool(
        profile
        and profile.start_date
        and profile.end_date
        and profile.max_rent_cents
        and profile.pin_latitude is not None
        and profile.pin_longitude is not None
        and profile.radius_m
    )


def renter_profile_out(profile: RenterProfile | None) -> RenterProfileOut:
    if profile is None:
        return RenterProfileOut(
            start_date=None,
            end_date=None,
            flexibility_days=0,
            max_rent_cents=None,
            preferences=[],
            pin=None,
            complete=False,
            updated_at=None,
        )
    pin = None
    if profile.pin_latitude is not None and profile.pin_longitude is not None:
        pin = Pin(
            latitude=profile.pin_latitude,
            longitude=profile.pin_longitude,
            radius_m=profile.radius_m,
        )
    return RenterProfileOut(
        start_date=profile.start_date,
        end_date=profile.end_date,
        flexibility_days=profile.flexibility_days,
        max_rent_cents=profile.max_rent_cents,
        preferences=[Preference(**item) for item in profile.preferences],
        pin=pin,
        complete=is_complete(profile),
        updated_at=profile.updated_at,
    )


@router.get("/me/renter-profile", response_model=RenterProfileOut)
def read_renter_profile(user: CurrentUser, session: DbSession) -> RenterProfileOut:
    """The caller's own renter profile. Empty until they save one."""
    return renter_profile_out(session.get(RenterProfile, user.id))


@router.put("/me/renter-profile", response_model=RenterProfileOut)
def save_renter_profile(
    body: RenterProfileIn, user: CurrentUser, session: DbSession
) -> RenterProfileOut:
    """Replace the caller's renter profile. A partly filled one may be saved."""
    preferences = [item.model_dump() for item in body.preferences]
    problems = preference_problems(preferences)
    if body.start_date and body.end_date and body.end_date <= body.start_date:
        problems.insert(
            0, FieldError(field="end_date", message="The end date must be after the start date.")
        )
    if problems:
        raise ApiError(
            422, "validation_error", "Some fields are missing or invalid.", fields=problems
        )

    profile = session.get(RenterProfile, user.id)
    if profile is None:
        profile = RenterProfile(user_id=user.id)
        session.add(profile)
    profile.start_date = body.start_date
    profile.end_date = body.end_date
    profile.flexibility_days = body.flexibility_days
    profile.max_rent_cents = body.max_rent_cents
    profile.preferences = preferences
    profile.pin_latitude = body.pin.latitude if body.pin else None
    profile.pin_longitude = body.pin.longitude if body.pin else None
    profile.radius_m = body.pin.radius_m if body.pin else None
    session.commit()
    session.refresh(profile)
    return renter_profile_out(profile)
