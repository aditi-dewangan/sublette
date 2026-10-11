"""Database engine, sessions and the reachability check used by /health."""

import logging
from collections.abc import Iterator
from dataclasses import dataclass

from fastapi import Request
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import DeclarativeBase, Session

from app.config import Settings

logger = logging.getLogger(__name__)


class Base(DeclarativeBase):
    """Parent of every table model. Alembic reads Base.metadata."""


def make_engine(settings: Settings) -> Engine:
    """Create the engine. This does not connect, so the app can start while
    the database is down and report that through /health."""
    return create_engine(
        settings.database_url,
        pool_pre_ping=True,
        connect_args={"connect_timeout": settings.db_connect_timeout_s},
    )


def get_session(request: Request) -> Iterator[Session]:
    """FastAPI dependency: one session per request, closed afterwards."""
    with Session(request.app.state.engine) as session:
        yield session


@dataclass(frozen=True)
class DatabaseStatus:
    reachable: bool
    postgis: str | None = None


def check_database(engine: Engine) -> DatabaseStatus:
    """Report whether the database answers, and the PostGIS version if installed.

    Never raises. The reason for a failure is logged, not returned, because
    /health is public and connection errors can contain host names.
    """
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
            postgis = connection.execute(
                text("SELECT extversion FROM pg_extension WHERE extname = 'postgis'")
            ).scalar_one_or_none()
    except SQLAlchemyError as error:
        logger.warning("Database check failed: %s", type(error).__name__)
        logger.debug("Database check failure detail", exc_info=error)
        return DatabaseStatus(reachable=False)
    return DatabaseStatus(reachable=True, postgis=postgis)
