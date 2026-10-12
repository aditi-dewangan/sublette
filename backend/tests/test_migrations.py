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

    from app.db import Base, include_in_migrations

    engine = create_engine(clean_database)
    try:
        with engine.connect() as connection:
            context = MigrationContext.configure(
                connection, opts={"include_object": include_in_migrations}
            )
            differences = compare_metadata(context, Base.metadata)
    finally:
        engine.dispose()

    def describe(difference) -> str:
        kind, item = difference[0], difference[1]
        table = getattr(item, "table", item)
        where = f"{getattr(table, 'schema', None)}.{getattr(table, 'name', '?')}"
        return f"{kind} {getattr(item, 'name', item)} on {where}"

    summary = [describe(d) if isinstance(d, tuple) else str(d) for d in differences]
    assert summary == []


def test_postgis_tables_and_their_indexes_are_left_alone() -> None:
    from sqlalchemy import Column, Index, Integer, MetaData, Table

    from app.db import include_in_migrations

    metadata = MetaData()
    topology = Table("topology", metadata, Column("id", Integer))
    tiger = Table("addr", metadata, Column("id", Integer), schema="tiger")
    ours = Table("users", metadata, Column("id", Integer))
    topology_index = Index("topology_name_key", topology.c.id)
    our_index = Index("ix_users_id", ours.c.id)

    assert not include_in_migrations(topology, "topology", "table", True, None)
    assert not include_in_migrations(tiger, "addr", "table", True, None)
    assert not include_in_migrations(topology_index, "topology_name_key", "index", True, None)
    assert include_in_migrations(ours, "users", "table", True, None)
    assert include_in_migrations(our_index, "ix_users_id", "index", True, None)
