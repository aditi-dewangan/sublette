"""Alembic environment: where migrations get their database URL and models."""

from logging.config import fileConfig

from sqlalchemy import create_engine

import app.models  # noqa: F401  (registers every table on Base.metadata)
from alembic import context
from app.config import get_settings
from app.db import Base, include_in_migrations

config = context.config

# Tests pass their own URL through config.attributes; otherwise use settings.
database_url = config.attributes.get("database_url") or get_settings().database_url

if config.config_file_name is not None and config.attributes.get("configure_logging", True):
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    context.configure(
        url=database_url,
        target_metadata=target_metadata,
        include_object=include_in_migrations,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    engine = create_engine(database_url)
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            include_object=include_in_migrations,
        )
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
