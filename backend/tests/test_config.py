import pytest

from app.config import LOCAL_DATABASE_URL, Settings


@pytest.fixture(autouse=True)
def _no_ambient_settings(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    """Hide the developer's own SUBLETTE_* variables and .env file."""
    for name in ("SUBLETTE_ENV", "SUBLETTE_DATABASE_URL", "SUBLETTE_DB_CONNECT_TIMEOUT_S"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.chdir(tmp_path)


def test_defaults_point_at_the_local_database() -> None:
    settings = Settings()

    assert settings.env == "local"
    assert settings.database_url == LOCAL_DATABASE_URL


def test_settings_are_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SUBLETTE_ENV", "staging")
    monkeypatch.setenv("SUBLETTE_DATABASE_URL", "postgresql+psycopg://u:p@db.example/app")

    settings = Settings()

    assert settings.env == "staging"
    assert settings.database_url == "postgresql+psycopg://u:p@db.example/app"


@pytest.mark.parametrize(
    "given",
    ["postgres://u:p@host:5432/app", "postgresql://u:p@host:5432/app"],
)
def test_hosting_platform_urls_get_the_psycopg_driver(given: str) -> None:
    assert Settings(database_url=given).database_url == "postgresql+psycopg://u:p@host:5432/app"


def test_unknown_environment_is_rejected() -> None:
    with pytest.raises(ValueError):
        Settings(env="prod")
