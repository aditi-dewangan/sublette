"""Turns every failure into the {code, message} shape."""

import logging
from http import HTTPStatus

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.schemas.errors import ErrorResponse, FieldError

logger = logging.getLogger(__name__)


def _code_for(status_code: int) -> str:
    try:
        return HTTPStatus(status_code).phrase.lower().replace(" ", "_").replace("-", "_")
    except ValueError:
        return "error"


def _respond(status_code: int, error: ErrorResponse, headers=None) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content=error.model_dump(exclude_none=True),
        headers=headers,
    )


def install_error_handlers(app: FastAPI) -> None:
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
                message=item["msg"],
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

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, error: Exception) -> JSONResponse:
        logger.exception("Unhandled error on %s %s", request.method, request.url.path)
        return _respond(
            500,
            ErrorResponse(code="internal_error", message="Something went wrong on our side."),
        )
