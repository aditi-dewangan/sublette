"""The one error shape every endpoint uses: {code, message}."""

from pydantic import BaseModel


class FieldError(BaseModel):
    field: str
    message: str


class ErrorResponse(BaseModel):
    code: str
    message: str
    # Present only on validation errors, so the app can show each message
    # beside the field that failed.
    fields: list[FieldError] | None = None
