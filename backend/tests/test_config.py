import pytest

from app.config import LOCAL_DATABASE_URL, Settings


@pytest.fixture(autouse=True)
def _no_env_file(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    """Hide the developer's own backend/.env file."""
    monkeypatch.chdir(tmp_path)


def test_defaults_point_at_the_local_database() -> None:
    settings = Settings()

    assert settings.env == "local"
    assert settings.database_url == LOCAL_DATABASE_URL


def test_settings_are_read_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SUBLETTE_ENV", "staging")
    monkeypatch.setenv("SUBLETTE_DATABASE_URL", "postgresql+psycopg://u:p@db.example/app")
    monkeypatch.setenv("SUBLETTE_SECRET_KEY", "s" * 48)

    settings = Settings()

    assert settings.env == "staging"
    assert settings.database_url == "postgresql+psycopg://u:p@db.example/app"


@pytest.mark.parametrize(
    "given",
    ["postgres://u:p@host:5432/app", "postgresql://u:p@host:5432/app"],
)
def test_hosting_platform_urls_get_the_psycopg_driver(given: str) -> None:
    assert Settings(database_url=given).database_url == "postgresql+psycopg://u:p@host:5432/app"


def test_a_neon_connection_string_keeps_its_ssl_options() -> None:
    given = (
        "postgresql://neondb_owner:pw@ep-cool-name-123.us-west-2.aws.neon.tech/neondb"
        "?sslmode=require&channel_binding=require"
    )

    assert Settings(database_url=given).database_url == (
        "postgresql+psycopg://neondb_owner:pw@ep-cool-name-123.us-west-2.aws.neon.tech/neondb"
        "?sslmode=require&channel_binding=require"
    )


def test_unknown_environment_is_rejected() -> None:
    with pytest.raises(ValueError):
        Settings(env="prod")


# --- Hosted servers refuse to start on developer defaults ---------------------

SECRET = "x" * 48


def test_staging_needs_a_real_secret() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_SECRET_KEY"):
        Settings(env="staging")
    with pytest.raises(ValueError, match="SUBLETTE_SECRET_KEY"):
        Settings(env="staging", secret_key="too-short")

    assert Settings(env="staging", secret_key=SECRET).env == "staging"


def test_production_refuses_to_log_codes_or_keep_photos_on_local_disk() -> None:
    with pytest.raises(ValueError) as error:
        Settings(env="production", secret_key=SECRET)

    assert "SUBLETTE_EMAIL_BACKEND" in str(error.value)
    assert "SUBLETTE_STORAGE_BACKEND" in str(error.value)


def test_smtp_needs_a_host() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_SMTP_HOST"):
        Settings(email_backend="smtp")


def test_s3_needs_its_bucket_and_keys() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_S3_BUCKET"):
        Settings(storage_backend="s3")


def test_a_fully_configured_production_server_is_accepted() -> None:
    settings = Settings(
        env="production",
        secret_key=SECRET,
        email_backend="smtp",
        smtp_host="smtp.example.test",
        storage_backend="s3",
        s3_bucket="photos",
        s3_access_key_id="key",
        s3_secret_access_key="secret",
        s3_public_base_url="https://photos.example.test/",
    )

    assert settings.s3_public_base_url == "https://photos.example.test"


def test_blocked_domains_are_parsed_from_a_comma_separated_list() -> None:
    settings = Settings(blocked_email_domains=" Alumni.Example.edu, @spam.edu ,")

    assert settings.blocked_domains == {"alumni.example.edu", "spam.edu"}
