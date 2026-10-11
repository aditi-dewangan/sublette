from typing import Literal

from pydantic import BaseModel


class DatabaseHealth(BaseModel):
    reachable: bool
    postgis: str | None = None


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    version: str
    environment: str
    database: DatabaseHealth
    # Set only when status is "degraded", so a client that understands the
    # standard {code, message} error shape can show the reason.
    code: str | None = None
    message: str | None = None
