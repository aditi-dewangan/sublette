"""Sending codes through Brevo's HTTPS API, and what happens when Brevo is unavailable."""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from app.config import Settings
from app.services.email_sender import BrevoEmailSender, EmailUnavailable, make_email_sender


class FakeBrevo:
    """A tiny HTTP server on localhost that answers like Brevo's send endpoint."""

    def __init__(self, status: int = 201, body: str = '{"messageId": "<1@brevo>"}') -> None:
        outer = self
        self.status = status
        self.body = body
        self.requests: list[dict] = []
        self.delay_s = 0.0

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers.get("content-length") or 0)
                outer.requests.append(
                    {
                        "path": self.path,
                        "headers": {name.lower(): value for name, value in self.headers.items()},
                        "json": json.loads(self.rfile.read(length)),
                    }
                )
                if outer.delay_s:
                    threading.Event().wait(outer.delay_s)
                self.send_response(outer.status)
                self.send_header("content-type", "application/json")
                self.end_headers()
                self.wfile.write(outer.body.encode())

            def log_message(self, *args) -> None:
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}/v3/smtp/email"
        threading.Thread(target=self._server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()


@pytest.fixture
def brevo():
    server = FakeBrevo()
    yield server
    server.close()


def brevo_settings(url: str, **changes) -> Settings:
    return Settings(
        email_backend="brevo",
        email_from="Sublette <sublette.app@example.com>",
        brevo_api_key="xkeysib-test",
        brevo_api_url=url,
        email_timeout_s=2,
        **changes,
    )


def test_the_setting_picks_brevo(brevo: FakeBrevo) -> None:
    assert isinstance(make_email_sender(brevo_settings(brevo.url)), BrevoEmailSender)


def test_the_code_is_sent_with_the_key_sender_and_text(brevo: FakeBrevo) -> None:
    BrevoEmailSender(brevo_settings(brevo.url)).send_code("aditi@uw.edu", "482913", 10)

    assert len(brevo.requests) == 1
    request = brevo.requests[0]
    assert request["path"] == "/v3/smtp/email"
    assert request["headers"]["api-key"] == "xkeysib-test"
    assert request["headers"]["content-type"] == "application/json"
    body = request["json"]
    assert body["sender"] == {"name": "Sublette", "email": "sublette.app@example.com"}
    assert body["to"] == [{"email": "aditi@uw.edu"}]
    assert body["subject"] == "482913 is your Sublette code"
    assert "482913" in body["textContent"]
    assert "10 minutes" in body["textContent"]
    assert "htmlContent" not in body


def test_a_bare_sender_address_gets_the_app_name(brevo: FakeBrevo) -> None:
    settings = brevo_settings(brevo.url).model_copy(update={"email_from": "me@example.com"})

    BrevoEmailSender(settings).send_code("aditi@uw.edu", "482913", 10)

    assert brevo.requests[0]["json"]["sender"] == {"name": "Sublette", "email": "me@example.com"}


# --- Dependency unavailable: Brevo ---------------------------------------------


@pytest.mark.parametrize(
    ("status", "body"),
    [
        (401, '{"code": "unauthorized", "message": "Key not found"}'),
        (400, '{"code": "invalid_parameter", "message": "sender is not valid"}'),
        (429, '{"code": "too_many_requests", "message": "Daily limit reached"}'),
        (500, "Internal Server Error"),
        (503, "Service Unavailable"),
    ],
)
def test_any_refusal_from_brevo_is_reported_as_unavailable(status: int, body: str, caplog) -> None:
    server = FakeBrevo(status=status, body=body)
    try:
        with pytest.raises(EmailUnavailable):
            BrevoEmailSender(brevo_settings(server.url)).send_code("aditi@uw.edu", "1", 10)
    finally:
        server.close()

    # The reason reaches the server log, so the owner can see why; the key never does.
    assert str(status) in caplog.text
    assert "xkeysib-test" not in caplog.text


def test_brevo_unreachable_is_reported_as_unavailable() -> None:
    sender = BrevoEmailSender(brevo_settings("http://127.0.0.1:1/v3/smtp/email"))

    with pytest.raises(EmailUnavailable):
        sender.send_code("aditi@uw.edu", "123456", 10)


def test_a_slow_brevo_gives_up_after_the_timeout(brevo: FakeBrevo) -> None:
    import time

    brevo.delay_s = 3
    sender = BrevoEmailSender(brevo_settings(brevo.url).model_copy(update={"email_timeout_s": 1}))

    started = time.monotonic()
    with pytest.raises(EmailUnavailable):
        sender.send_code("aditi@uw.edu", "123456", 10)

    assert time.monotonic() - started < 2.5


def test_sign_up_through_brevo_end_to_end(settings, clock, brevo: FakeBrevo) -> None:
    from fastapi.testclient import TestClient

    from app.deps import get_now
    from app.main import create_app

    app = create_app(
        settings.model_copy(
            update={
                "email_backend": "brevo",
                "email_from": "Sublette <sublette.app@example.com>",
                "brevo_api_key": "xkeysib-test",
                "brevo_api_url": brevo.url,
            }
        )
    )
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        assert (
            client.post("/v1/auth/request-code", json={"email": "aditi@uw.edu"}).status_code == 200
        )
        code = brevo.requests[0]["json"]["subject"].split()[0]
        verified = client.post("/v1/auth/verify", json={"email": "aditi@uw.edu", "code": code})

        brevo.status = 503
        down = client.post("/v1/auth/request-code", json={"email": "sam@uw.edu"})

    assert verified.status_code == 200
    assert down.status_code == 503
    assert down.json()["code"] == "email_unavailable"


# --- Settings -------------------------------------------------------------------


def test_brevo_needs_a_key() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_BREVO_API_KEY"):
        Settings(email_backend="brevo", email_from="Sublette <a@example.com>")


def test_brevo_needs_a_real_sender_address() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_EMAIL_FROM"):
        Settings(email_backend="brevo", brevo_api_key="k", email_from="Sublette")


def test_a_free_staging_setup_is_accepted() -> None:
    """The $0 setup: Brevo for email, no photo storage."""
    settings = Settings(
        env="staging",
        secret_key="s" * 44,
        email_backend="brevo",
        brevo_api_key="xkeysib-real",
        email_from="Sublette <sublette.app@gmail.com>",
        storage_backend="none",
    )

    assert settings.email_backend == "brevo"


# --- Development inbox: every code to one address -----------------------------


def test_with_a_redirect_every_code_goes_to_the_dev_inbox(brevo: FakeBrevo) -> None:
    settings = brevo_settings(brevo.url).model_copy(
        update={"email_redirect_to": "subletteofficial+dev@gmail.com"}
    )

    BrevoEmailSender(settings).send_code("made-up-student@uw.edu", "482913", 10)

    body = brevo.requests[0]["json"]
    assert body["to"] == [{"email": "subletteofficial+dev@gmail.com"}]
    assert body["subject"] == "[LOCAL] 482913 is your Sublette code (for made-up-student@uw.edu)"
    assert "made-up-student@uw.edu" in body["textContent"]
    assert "482913" in body["textContent"]


def test_without_a_redirect_the_code_goes_to_the_student(brevo: FakeBrevo) -> None:
    BrevoEmailSender(brevo_settings(brevo.url)).send_code("aditi@uw.edu", "482913", 10)

    body = brevo.requests[0]["json"]
    assert body["to"] == [{"email": "aditi@uw.edu"}]
    assert body["subject"] == "482913 is your Sublette code"


def test_staging_labels_redirected_codes_as_staging(brevo: FakeBrevo) -> None:
    settings = brevo_settings(brevo.url).model_copy(
        update={"env": "staging", "email_redirect_to": "subletteofficial+dev@gmail.com"}
    )

    BrevoEmailSender(settings).send_code("aditi@uw.edu", "482913", 10)

    assert brevo.requests[0]["json"]["subject"].startswith("[STAGING] ")


def test_production_refuses_a_redirect() -> None:
    with pytest.raises(ValueError, match="SUBLETTE_EMAIL_REDIRECT_TO"):
        Settings(
            env="production",
            secret_key="s" * 44,
            email_backend="brevo",
            brevo_api_key="k",
            email_from="Sublette <a@example.com>",
            storage_backend="s3",
            s3_bucket="b",
            s3_access_key_id="k",
            s3_secret_access_key="s",
            s3_public_base_url="https://photos.example.test",
            email_redirect_to="subletteofficial+dev@gmail.com",
        )


def test_a_redirect_must_be_an_address() -> None:
    with pytest.raises(ValueError, match="must be an email address"):
        Settings(email_redirect_to="DEV folder")
