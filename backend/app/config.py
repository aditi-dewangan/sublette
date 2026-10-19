"""Settings, read from environment variables prefixed with SUBLETTE_.

Example: SUBLETTE_DATABASE_URL, SUBLETTE_ENV. A local `.env` file in backend/
is also read. Nothing here is specific to one school or one city.

The defaults make `make dev` work with no configuration. Staging and
production refuse to start on those defaults where that would be unsafe.
"""

from email.utils import parseaddr
from functools import lru_cache
from typing import Literal, Self

from pydantic import AliasChoices, Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

Environment = Literal["local", "test", "staging", "production"]

LOCAL_DATABASE_URL = "postgresql+psycopg://sublette:sublette@localhost:5432/sublette"
# Signs tokens and hashes codes on a developer's machine only.
LOCAL_SECRET_KEY = "local-development-secret-not-for-real-users"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SUBLETTE_",
        env_file=".env",
        extra="ignore",
        populate_by_name=True,
    )

    env: Environment = "local"

    # --- Database ---
    database_url: str = LOCAL_DATABASE_URL
    # How long a request waits for the database before giving up. Kept short so
    # that /health answers quickly when the database is down.
    db_connect_timeout_s: int = 3

    # --- Sign-in ---
    # Signs access and refresh tokens and keys the hash of emailed codes.
    # Generate one with: python -c "import secrets; print(secrets.token_urlsafe(48))"
    secret_key: str = LOCAL_SECRET_KEY
    access_token_minutes: int = 15
    refresh_token_days: int = 60
    code_ttl_minutes: int = 10
    code_max_attempts: int = 5
    # Comma-separated email domains that may not sign up, e.g. "alumni.example.edu".
    blocked_email_domains: str = ""

    # --- Rate limits ---
    code_resend_wait_s: int = 30
    code_requests_per_email_per_hour: int = 5
    # Generous, because a whole campus can share one address.
    code_requests_per_ip_per_hour: int = 100
    verify_attempts_per_ip_per_hour: int = 200

    # --- Email ---
    # "console" prints the code in the server log instead of sending it.
    # "smtp" sends through any SMTP provider.
    # "brevo" sends through Brevo's HTTPS API. Use it where SMTP ports are
    # blocked, such as Render's free plan.
    email_backend: Literal["console", "smtp", "brevo"] = "console"
    email_from: str = "Sublette <no-reply@localhost>"
    # Development and staging only: send every code here instead of to the
    # student, e.g. "subletteofficial+dev@gmail.com". Refused in production.
    email_redirect_to: str = ""
    # Also print every sign-in code in the server's terminal, as well as
    # emailing it. Unset means on for a local server and off everywhere else.
    # While on, a failed email still lets the student sign in with the printed
    # code. Refused in production.
    email_echo_codes: bool | None = None
    brevo_api_key: str = ""
    brevo_api_url: str = "https://api.brevo.com/v3/smtp/email"
    # Seconds to wait for an HTTPS email provider.
    email_timeout_s: int = 10
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_security: Literal["starttls", "ssl", "none"] = "starttls"
    smtp_timeout_s: int = 10

    # --- Photo storage ---
    # "local" keeps photos in a folder and serves them from this server.
    # "database" keeps them in a database table and serves them from this
    # server (free; survives restarts). "s3" is any S3-compatible store.
    # "none" turns uploads off.
    storage_backend: Literal["local", "database", "s3", "none"] = "local"
    storage_local_dir: str = ".dev-storage"
    # Where phones reach this server; used to build photo addresses when this
    # server stores the photos. On Render it is filled in automatically.
    public_base_url: str = Field(
        default="http://localhost:8000",
        validation_alias=AliasChoices("SUBLETTE_PUBLIC_BASE_URL", "RENDER_EXTERNAL_URL"),
    )
    s3_bucket: str = ""
    s3_region: str = "auto"
    s3_endpoint_url: str = ""
    s3_access_key_id: str = ""
    s3_secret_access_key: str = ""
    # Public address the bucket's files are served from, with no trailing slash.
    s3_public_base_url: str = ""
    upload_max_bytes: int = 10 * 1024 * 1024
    upload_url_ttl_s: int = 600

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

    @field_validator("public_base_url", "s3_public_base_url")
    @classmethod
    def _no_trailing_slash(cls, value: str) -> str:
        return value.rstrip("/")

    @property
    def echo_codes(self) -> bool:
        """True when sign-in codes are also printed in the terminal."""
        if self.email_echo_codes is None:
            return self.env == "local"
        return self.email_echo_codes and self.env != "production"

    @model_validator(mode="after")
    def _refuse_unsafe_settings(self) -> Self:
        """Stop a hosted server from starting on developer defaults."""
        problems = []
        hosted = self.env in ("staging", "production")
        if hosted and (self.secret_key == LOCAL_SECRET_KEY or len(self.secret_key) < 32):
            problems.append("SUBLETTE_SECRET_KEY must be set to a random value of 32+ characters")
        if self.env == "production" and self.email_backend == "console":
            problems.append("SUBLETTE_EMAIL_BACKEND=console would log sign-in codes; use smtp")
        if self.env == "production" and self.storage_backend == "local":
            problems.append("SUBLETTE_STORAGE_BACKEND=local loses photos on redeploy; use s3")
        if self.env == "production" and self.email_echo_codes:
            problems.append(
                "SUBLETTE_EMAIL_ECHO_CODES would print students' sign-in codes in the "
                "server log; it is for development only"
            )
        if self.env == "production" and self.email_redirect_to:
            problems.append(
                "SUBLETTE_EMAIL_REDIRECT_TO would send every student's code to one inbox; "
                "it is for development and staging only"
            )
        if self.email_redirect_to and "@" not in self.email_redirect_to:
            problems.append("SUBLETTE_EMAIL_REDIRECT_TO must be an email address")
        if self.email_backend == "smtp" and not self.smtp_host:
            problems.append("SUBLETTE_SMTP_HOST is required when SUBLETTE_EMAIL_BACKEND=smtp")
        if self.email_backend == "brevo":
            if not self.brevo_api_key:
                problems.append(
                    "SUBLETTE_BREVO_API_KEY is required when SUBLETTE_EMAIL_BACKEND=brevo"
                )
            if "@" not in parseaddr(self.email_from)[1]:
                problems.append(
                    "SUBLETTE_EMAIL_FROM must be a sender Brevo has verified, "
                    'such as "Sublette <you@example.com>"'
                )
        if self.storage_backend == "s3":
            missing = [
                name
                for name in (
                    "s3_bucket",
                    "s3_access_key_id",
                    "s3_secret_access_key",
                    "s3_public_base_url",
                )
                if not getattr(self, name)
            ]
            if missing:
                names = ", ".join(f"SUBLETTE_{name.upper()}" for name in missing)
                problems.append(f"{names} required when SUBLETTE_STORAGE_BACKEND=s3")
        if problems:
            raise ValueError("; ".join(problems))
        return self

    @property
    def blocked_domains(self) -> frozenset[str]:
        return frozenset(
            part.strip().lower().lstrip("@")
            for part in self.blocked_email_domains.split(",")
            if part.strip()
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
