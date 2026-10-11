"""Settings, read from environment variables prefixed with SUBLETTE_.

Example: SUBLETTE_DATABASE_URL, SUBLETTE_ENV. A local `.env` file in backend/
is also read. Nothing here is specific to one school or one city.
"""

from functools import lru_cache
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["local", "test", "staging", "production"]

LOCAL_DATABASE_URL = "postgresql+psycopg://sublette:sublette@localhost:5432/sublette"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SUBLETTE_",
        env_file=".env",
        extra="ignore",
    )

    env: Environment = "local"
    database_url: str = LOCAL_DATABASE_URL
    # How long a request waits for the database before giving up. Kept short so
    # that /health answers quickly when the database is down.
    db_connect_timeout_s: int = 3

    @field_validator("database_url")
    @classmethod
    def _use_psycopg_driver(cls, value: str) -> str:
        """Accept the URL forms that hosting platforms hand out.

        Managed Postgres providers give `postgres://...` or `postgresql://...`.
        SQLAlchemy needs the driver named, so both become `postgresql+psycopg://`.
        """
        for prefix in ("postgres://", "postgresql://"):
            if value.startswith(prefix):
                return "postgresql+psycopg://" + value[len(prefix) :]
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()
