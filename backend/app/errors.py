"""Turns every failure into the {code, message} shape."""

import logging
from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import InterfaceError, OperationalError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.schemas.errors import ErrorResponse, FieldError

logger = logging.getLogger(__name__)


class ApiError(Exception):
    """An error with its own code, raised by routes and services.

    `code` is what the app switches on; `message` is safe to show to the user.
    """

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        fields: list[FieldError] | None = None,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.fields = fields
        self.headers = headers


def _code_for(status_code: int) -> str:
    try:
        return HTTPStatus(status_code).phrase.lower().replace(" ", "_").replace("-", "_")
    except ValueError:
        return "error"


def _friendly(item: dict) -> str:
    """A message a student can act on, in place of the validator's own wording."""
    kind = item["type"]
    context = item.get("ctx") or {}
    if kind == "missing":
        return "This is required."
    if kind == "string_too_short":
        return "This can't be empty."
    if kind == "string_too_long":
        return f"Keep this to {context.get('max_length')} characters or fewer."
    if kind in ("literal_error", "enum"):
        return "Choose one of the options."
    if kind == "string_pattern_mismatch":
        return "That isn't in the right format."
    if kind == "extra_forbidden":
        return "This can't be changed."
    if kind in ("greater_than", "greater_than_equal"):
        return f"This must be more than {context.get('gt', context.get('ge'))}."
    if kind in ("less_than", "less_than_equal"):
        return f"This must be less than {context.get('lt', context.get('le'))}."
    return "That isn't a valid value."


def _respond(status_code: int, error: ErrorResponse, headers=None) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=error.model_dump(exclude_none=True),
        headers=headers,
    )


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def api_error(request: Request, error: ApiError) -> JSONResponse:
        return _respond(
            error.status_code,
            ErrorResponse(code=error.code, message=error.message, fields=error.fields),
            headers=error.headers,
        )

    @app.exception_handler(StarletteHTTPException)
    async def http_error(request: Request, error: StarletteHTTPException) -> JSONResponse:
        message = error.detail if isinstance(error.detail, str) else _code_for(error.status_code)
        return _respond(
            error.status_code,
            ErrorResponse(code=_code_for(error.status_code), message=message),
            headers=error.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, error: RequestValidationError) -> JSONResponse:
        fields = [
            FieldError(
                # Drop the leading "body" / "query" / "path" part of the location.
                field=".".join(str(part) for part in item["loc"][1:]) or str(item["loc"][0]),
                message=_friendly(item),
            )
            for item in error.errors()
        ]
        return _respond(
            422,
            ErrorResponse(
                code="validation_error",
                message="Some fields are missing or invalid.",
                fields=fields,
            ),
        )

    @app.exception_handler(OperationalError)
    @app.exception_handler(InterfaceError)
    async def database_down(request: Request, error: Exception) -> JSONResponse:
        """The database could not be reached. Say so plainly instead of a 500."""
        logger.warning(
            "Database unavailable on %s %s: %s",
            request.method,
            request.url.path,
            type(error).__name__,
        )
        return _respond(
            503,
            ErrorResponse(
                code="service_unavailable",
                message="Sublette is having trouble right now. Try again in a minute.",
            ),
            headers={"Retry-After": "30"},
        )

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, error: Exception) -> JSONResponse:
        logger.exception("Unhandled error on %s %s", request.method, request.url.path)
        return _respond(
            500,
            ErrorResponse(code="internal_error", message="Something went wrong on our side."),
        )
