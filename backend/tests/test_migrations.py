"""Alembic is wired up: one head, and it applies to a real database."""

from alembic.command import downgrade, upgrade
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from tests.conftest import alembic_config


def _current_revision(database_url: str) -> str | None:
    engine = create_engine(database_url)
    try:
        with engine.connect() as connection:
            return connection.execute(text("SELECT version_num FROM alembic_version")).scalar()
    finally:
        engine.dispose()


def test_there_is_exactly_one_migration_head(migrated_database: str) -> None:
    script = ScriptDirectory.from_config(alembic_config(migrated_database))

    assert len(script.get_heads()) == 1


def test_migrations_apply_and_roll_back(migrated_database: str) -> None:
    database_url = migrated_database
    config = alembic_config(database_url)
    head = ScriptDirectory.from_config(config).get_current_head()

    upgrade(config, "head")
    assert _current_revision(database_url) == head

    downgrade(config, "base")
    assert _current_revision(database_url) is None

    upgrade(config, "head")
    assert _current_revision(database_url) == head


def test_models_and_migrations_agree(clean_database: str) -> None:
    """Fails when a model changes and nobody writes the migration for it."""
    from alembic.autogenerate import compare_metadata
    from alembic.migration import MigrationContext

    from app.db import Base

    engine = create_engine(clean_database)
    try:
        with engine.connect() as connection:
            context = MigrationContext.configure(
                connection,
                opts={
                    "include_object": lambda obj, name, type_, reflected, compare_to: (
                        not (type_ == "table" and name == "spatial_ref_sys")
                    )
                },
            )
            differences = compare_metadata(context, Base.metadata)
    finally:
        engine.dispose()

    assert differences == []
