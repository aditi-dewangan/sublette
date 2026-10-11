from fastapi import APIRouter, Request, Response

from app import __version__
from app.db import check_database
from app.schemas.health import DatabaseHealth, HealthResponse

router = APIRouter(tags=["health"])

HEALTH_PATH = "/health"


@router.get(
    HEALTH_PATH,
    response_model=HealthResponse,
    response_model_exclude_none=True,
    responses={503: {"model": HealthResponse, "description": "Database unreachable"}},
)
def health(request: Request, response: Response) -> HealthResponse:
    """App version, and whether the database is reachable.

    Answers 503 (never hangs, never crashes) when the database is down.
    """
    state = request.app.state
    database = check_database(state.engine)
    body = HealthResponse(
        status="ok" if database.reachable else "degraded",
        version=__version__,
        environment=state.settings.env,
        database=DatabaseHealth(reachable=database.reachable, postgis=database.postgis),
    )
    # Health results must never be cached by a proxy or by the phone.
    response.headers["Cache-Control"] = "no-store"
    if not database.reachable:
        response.status_code = 503
        body.code = "database_unreachable"
        body.message = "The server is running but cannot reach its database."
    return body
