"""The assistant: describe a place in plain words, get a short list."""

from datetime import timedelta

from fastapi import APIRouter, Request

from app.deps import AppSettings, CurrentUser, DbSession, Now, Storage
from app.errors import ApiError
from app.schemas.assistant import AssistantAnswer, AssistantQueryIn, AssistantStatus
from app.services import rate_limit
from app.services.assistant import LABEL, answer, log
from app.services.deck import renter_for

router = APIRouter(prefix="/assistant", tags=["assistant"])


@router.get("", response_model=AssistantStatus)
def status(user: CurrentUser, settings: AppSettings) -> AssistantStatus:
    """Whether the app shows the Assistant screen. Turning the setting off
    hides it at the next check, with no app update."""
    return AssistantStatus(enabled=settings.assistant_enabled, label=LABEL)


@router.post("/query", response_model=AssistantAnswer)
def query(
    body: AssistantQueryIn,
    request: Request,
    user: CurrentUser,
    session: DbSession,
    settings: AppSettings,
    storage: Storage,
    now: Now,
) -> AssistantAnswer:
    """Understand the message, find up to 20 eligible listings with it, and
    rank and explain the best. Nothing is saved to the profile; the app
    offers that as a separate step. Answers 409 until the search is set up."""
    if not settings.assistant_enabled:
        raise ApiError(403, "assistant_off", "The assistant isn't available right now.")
    renter = renter_for(session, user)
    rate_limit.hit(
        session,
        f"assistant:{user.id}",
        limit=settings.assistant_queries_per_hour,
        window=timedelta(hours=1),
        now=now,
    )
    model = request.app.state.language_model
    outcome = answer(session, user, renter, body.message, model, storage, now.date())
    log(session, user, body.message, outcome, model.name if model else "rules", now)
    session.commit()
    return outcome.answer
