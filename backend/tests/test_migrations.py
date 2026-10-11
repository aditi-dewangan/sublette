"""Alembic is wired up: one head, and it applies to a real database."""

from alembic.command import downgrade, upgrade
from alembic.config import Config
from alembic.script import ScriptDirectory
from sqlalchemy import create_engine, text

from tests.conftest import BACKEND_ROOT


def _alembic_config(database_url: str) -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.attributes["database_url"] = database_url
    config.attributes["configure_logging"] = False
    return config


def _current_revision(database_url: str) -> str | None:
    engine = create_engine(database_url)
    try:
        with engine.connect() as connection:
            return connection.execute(text("SELECT version_num FROM alembic_version")).scalar()
    finally:
        engine.dispose()


def test_there_is_exactly_one_migration_head(database_url: str) -> None:
    script = ScriptDirectory.from_config(_alembic_config(database_url))

    assert len(script.get_heads()) == 1


def test_migrations_apply_and_roll_back(database_url: str) -> None:
    config = _alembic_config(database_url)
    head = ScriptDirectory.from_config(config).get_current_head()

    upgrade(config, "head")
    assert _current_revision(database_url) == head

    downgrade(config, "base")
    assert _current_revision(database_url) is None

    upgrade(config, "head")
    assert _current_revision(database_url) == head
