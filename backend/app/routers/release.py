"""What the app reports about itself: feature use, crashes, and the referral
code a new lister was given."""

from datetime import timedelta

from fastapi import APIRouter, Response
from sqlalchemy import func, select

from app.deps import AppSettings, CurrentUser, DbSession, Now, Storage
from app.errors import ApiError
from app.models import CrashReport, Listing, User
from app.routers.me import user_out
from app.schemas.release import CrashIn, EventIn, ReferralIn
from app.schemas.user import UserOut
from app.services import analytics, rate_limit

router = APIRouter(tags=["release"])


@router.post("/events", status_code=204, response_class=Response)
def app_event(
    body: EventIn, user: CurrentUser, session: DbSession, settings: AppSettings, now: Now
) -> Response:
    if body.name == "feature_used" and body.feature is None:
        raise ApiError(422, "feature_required", "Say which feature was used.")
    rate_limit.hit(
        session,
        f"events:{user.id}",
        limit=settings.events_per_hour,
        window=timedelta(hours=1),
        now=now,
    )
    analytics.record(session, body.name, now, user_id=user.id, detail=body.feature)
    session.commit()
    return Response(status_code=204)


@router.post("/diagnostics", status_code=204, response_class=Response)
def crash_report(
    body: CrashIn, user: CurrentUser, session: DbSession, settings: AppSettings, now: Now
) -> Response:
    """A crash or hang from the phone, for the admin page's crash-free rate."""
    rate_limit.hit(
        session,
        f"crashes:{user.id}",
        limit=settings.crash_reports_per_day,
        window=timedelta(days=1),
        now=now,
    )
    session.add(
        CrashReport(
            user_id=user.id,
            kind=body.kind,
            app_version=body.app_version,
            os_version=body.os_version,
            payload=body.payload,
            created_at=now,
        )
    )
    session.commit()
    return Response(status_code=204)


def normalize_code(text: str) -> str:
    return "".join(character for character in text.upper() if character.isalnum())


@router.post("/me/referral", response_model=UserOut)
def use_referral(
    body: ReferralIn,
    user: CurrentUser,
    session: DbSession,
    settings: AppSettings,
    storage: Storage,
) -> UserOut:
    """Record the friend's code this student was given. Once per account, and
    only before their first listing goes live."""
    if user.referred_by_id is not None:
        raise ApiError(409, "referral_already_used", "You've already added a referral code.")
    published = session.scalar(
        select(func.count()).where(Listing.owner_id == user.id, Listing.published_at.is_not(None))
    )
    if published:
        raise ApiError(
            409,
            "referral_too_late",
            "Referral codes are for new listers, before their first listing goes live.",
        )
    referrer = session.scalar(select(User).where(User.referral_code == normalize_code(body.code)))
    if referrer is None or referrer.status != "active":
        raise ApiError(
            404, "referral_not_found", "That code doesn't match anyone. Check it and try again."
        )
    if referrer.id == user.id:
        raise ApiError(
            422,
            "own_referral_code",
            "That's your own code. Ask the friend who sent you for theirs.",
        )
    user.referred_by_id = referrer.id
    session.commit()
    session.refresh(user)
    return user_out(user, storage, settings)
