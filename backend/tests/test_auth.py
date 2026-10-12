"""Sign-up and sign-in with a six-digit code emailed to a .edu address."""

from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import EmailCode, RateLimitHit, School, SchoolDomain, User
from tests.conftest import Clock, RecordingMailer, bearer, sign_in

REQUEST = "/v1/auth/request-code"
VERIFY = "/v1/auth/verify"
REFRESH = "/v1/auth/refresh"


def request_code(client: TestClient, email: str):
    return client.post(REQUEST, json={"email": email})


def verify(client: TestClient, email: str, code: str):
    return client.post(VERIFY, json={"email": email, "code": code})


def wrong(code: str) -> str:
    """A six-digit code that is certainly not `code`."""
    return f"{(int(code) + 1) % 1_000_000:06d}"


# --- Requesting a code --------------------------------------------------------


def test_a_code_is_emailed_to_a_school_address(client: TestClient, mailer: RecordingMailer) -> None:
    response = request_code(client, "Aditi@UW.edu")

    assert response.status_code == 200
    assert response.json() == {"expires_in": 600, "resend_in": 30}
    assert len(mailer.sent) == 1
    to, code = mailer.sent[0]
    assert to == "aditi@uw.edu"
    assert len(code) == 6 and code.isdigit()


@pytest.mark.parametrize(
    "email", ["aditi@gmail.com", "aditi@student.unimelb.edu.au", "aditi@uw.edu.evil.com"]
)
def test_an_email_that_does_not_end_in_edu_is_refused_with_a_clear_message(
    client: TestClient, mailer: RecordingMailer, email: str
) -> None:
    response = request_code(client, email)

    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "not_edu_email"
    assert ".edu" in body["message"]
    assert body["fields"][0]["field"] == "email"
    assert mailer.sent == []


def test_something_that_is_not_an_email_is_refused(client: TestClient) -> None:
    response = request_code(client, "not an email")

    assert response.status_code == 422
    assert response.json()["code"] == "invalid_email"


def test_a_blocklisted_domain_is_refused(settings, clock, mailer: RecordingMailer) -> None:
    from app.deps import get_now
    from app.main import create_app

    app = create_app(settings.model_copy(update={"blocked_email_domains": "alumni.uw.edu"}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        blocked = request_code(client, "old@alumni.uw.edu")
        allowed = request_code(client, "new@uw.edu")

    assert blocked.status_code == 403
    assert blocked.json()["code"] == "domain_blocked"
    assert allowed.status_code == 200


def test_only_a_hash_of_the_code_is_stored(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")

    row = db.scalars(select(EmailCode)).one()

    assert row.email == "aditi@uw.edu"
    assert code not in row.code_hash
    assert len(row.code_hash) == 64
    assert row.attempts == 0


def test_the_same_code_hashes_differently_for_two_emails(settings) -> None:
    from app.services.codes import hash_code

    assert hash_code(settings, "a@uw.edu", "123456") != hash_code(settings, "b@uw.edu", "123456")


def test_a_new_code_replaces_the_old_one(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    request_code(client, "aditi@uw.edu")
    first = mailer.code_for("aditi@uw.edu")
    clock.advance(seconds=31)
    request_code(client, "aditi@uw.edu")
    second = mailer.code_for("aditi@uw.edu")

    if first != second:  # one time in a million they are the same
        assert verify(client, "aditi@uw.edu", first).status_code == 400
    assert verify(client, "aditi@uw.edu", second).status_code == 200


# --- Verifying ----------------------------------------------------------------


def test_the_right_code_verifies_the_account_and_returns_tokens(
    client: TestClient, mailer: RecordingMailer, db: Session, clock: Clock
) -> None:
    request_code(client, "aditi@uw.edu")

    response = verify(client, "aditi@uw.edu", mailer.code_for("aditi@uw.edu"))

    assert response.status_code == 200
    body = response.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 15 * 60
    assert body["access_token"] and body["refresh_token"]
    assert body["user"]["email"] == "aditi@uw.edu"
    assert body["user"]["verified"] is True
    assert body["user"]["profile_complete"] is False
    assert body["user"]["school"]["name"] == "University of Washington"

    user = db.scalars(select(User)).one()
    assert user.verified_at == clock.now
    assert db.scalar(select(func.count()).select_from(EmailCode)) == 0


def test_emails_from_two_different_schools_both_work(
    client: TestClient, mailer: RecordingMailer
) -> None:
    uw = sign_in(client, mailer, "aditi@uw.edu")
    northeastern = sign_in(client, mailer, "sam@northeastern.edu")

    assert uw["user"]["school"]["name"] == "University of Washington"
    assert northeastern["user"]["school"]["name"] == "Northeastern University"
    assert uw["user"]["school"]["id"] != northeastern["user"]["school"]["id"]


def test_a_department_address_belongs_to_the_same_school(
    client: TestClient, mailer: RecordingMailer
) -> None:
    main = sign_in(client, mailer, "aditi@uw.edu")
    department = sign_in(client, mailer, "lee@cs.washington.edu")

    assert department["user"]["school"]["id"] == main["user"]["school"]["id"]


def test_an_unknown_edu_domain_is_accepted_and_stored_under_its_domain(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    first = sign_in(client, mailer, "kai@students.smallcollege.edu")
    second = sign_in(client, mailer, "ana@smallcollege.edu")

    assert first["user"]["school"]["name"] == "smallcollege.edu"
    assert second["user"]["school"]["id"] == first["user"]["school"]["id"]
    domain = db.get(SchoolDomain, "smallcollege.edu")
    assert domain is not None and domain.school.name is None


def test_naming_an_unknown_school_later_updates_its_students(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    session_body = sign_in(client, mailer, "kai@smallcollege.edu")
    school = db.get(School, session_body["user"]["school"]["id"])
    school.name = "Small College"
    db.commit()

    me = client.get("/v1/me", headers=bearer(session_body))

    assert me.json()["school"]["name"] == "Small College"


def test_a_wrong_code_is_refused_and_counted(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")

    response = verify(client, "aditi@uw.edu", wrong(code))

    assert response.status_code == 400
    assert response.json() == {
        "code": "code_invalid",
        "message": "That code isn't right. 4 tries left.",
    }
    assert db.scalars(select(EmailCode)).one().attempts == 1
    assert db.scalar(select(func.count()).select_from(User)) == 0
    # The right code still works after one mistake.
    assert verify(client, "aditi@uw.edu", code).status_code == 200


def test_five_wrong_codes_lock_the_code_even_against_the_right_one(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")

    statuses = [verify(client, "aditi@uw.edu", wrong(code)) for _ in range(5)]

    assert [r.status_code for r in statuses] == [400, 400, 400, 400, 429]
    assert statuses[3].json()["message"] == "That code isn't right. 1 try left."
    assert statuses[4].json()["code"] == "code_locked"

    locked = verify(client, "aditi@uw.edu", code)
    assert locked.status_code == 429
    assert locked.json()["code"] == "code_locked"
    assert db.scalar(select(func.count()).select_from(User)) == 0


def test_a_new_code_works_after_a_lockout(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")
    for _ in range(5):
        verify(client, "aditi@uw.edu", wrong(code))

    clock.advance(seconds=31)
    assert request_code(client, "aditi@uw.edu").status_code == 200

    assert verify(client, "aditi@uw.edu", mailer.code_for("aditi@uw.edu")).status_code == 200


def test_a_code_expires_after_ten_minutes(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")

    clock.advance(minutes=9, seconds=59)
    still_valid = verify(client, "aditi@uw.edu", wrong(code))
    clock.advance(seconds=1)
    expired = verify(client, "aditi@uw.edu", code)

    assert still_valid.json()["code"] == "code_invalid"
    assert expired.status_code == 400
    assert expired.json()["code"] == "code_expired"


def test_a_code_works_only_once(client: TestClient, mailer: RecordingMailer) -> None:
    request_code(client, "aditi@uw.edu")
    code = mailer.code_for("aditi@uw.edu")

    assert verify(client, "aditi@uw.edu", code).status_code == 200
    again = verify(client, "aditi@uw.edu", code)

    assert again.status_code == 400
    assert again.json()["code"] == "code_invalid"


def test_a_code_for_one_email_does_not_work_for_another(
    client: TestClient, mailer: RecordingMailer
) -> None:
    request_code(client, "aditi@uw.edu")
    request_code(client, "sam@uw.edu")

    response = verify(client, "sam@uw.edu", mailer.code_for("aditi@uw.edu"))

    if mailer.code_for("aditi@uw.edu") != mailer.code_for("sam@uw.edu"):
        assert response.status_code == 400


def test_verifying_with_no_code_requested_is_refused(client: TestClient) -> None:
    response = verify(client, "aditi@uw.edu", "123456")

    assert response.status_code == 400
    assert response.json()["code"] == "code_invalid"


def test_a_code_that_is_not_six_digits_is_a_validation_error(client: TestClient) -> None:
    response = verify(client, "aditi@uw.edu", "12345")

    assert response.status_code == 422
    assert response.json()["fields"][0]["field"] == "code"


def test_signing_in_again_returns_the_same_account(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    first = sign_in(client, mailer, "aditi@uw.edu")
    first_verified_at = db.scalars(select(User)).one().verified_at
    clock.advance(days=3)

    second = sign_in(client, mailer, "ADITI@uw.edu")

    assert second["user"]["id"] == first["user"]["id"]
    assert db.scalar(select(func.count()).select_from(User)) == 1
    db.expire_all()
    assert db.scalars(select(User)).one().verified_at == first_verified_at


def test_a_suspended_account_cannot_sign_in(
    client: TestClient, mailer: RecordingMailer, db: Session, clock: Clock
) -> None:
    sign_in(client, mailer, "aditi@uw.edu")
    db.scalars(select(User)).one().status = "suspended"
    db.commit()
    clock.advance(seconds=31)

    request_code(client, "aditi@uw.edu")
    response = verify(client, "aditi@uw.edu", mailer.code_for("aditi@uw.edu"))

    assert response.status_code == 403
    assert response.json()["code"] == "account_suspended"


# --- Rate limits --------------------------------------------------------------


def test_a_second_code_cannot_be_requested_straight_away(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    assert request_code(client, "aditi@uw.edu").status_code == 200

    too_soon = request_code(client, "aditi@uw.edu")

    assert too_soon.status_code == 429
    assert too_soon.json()["code"] == "rate_limited"
    assert too_soon.headers["Retry-After"] == "30"
    assert "30 seconds" in too_soon.json()["message"]
    assert len(mailer.sent) == 1

    clock.advance(seconds=30)
    assert request_code(client, "aditi@uw.edu").status_code == 200


def test_at_most_five_codes_an_hour_per_email(
    client: TestClient, mailer: RecordingMailer, clock: Clock
) -> None:
    for _ in range(5):
        assert request_code(client, "aditi@uw.edu").status_code == 200
        clock.advance(minutes=1)

    sixth = request_code(client, "aditi@uw.edu")

    assert sixth.status_code == 429
    assert sixth.json()["code"] == "rate_limited"
    assert int(sixth.headers["Retry-After"]) == 55 * 60
    assert len(mailer.sent) == 5
    # Another student is not affected.
    assert request_code(client, "sam@uw.edu").status_code == 200

    clock.advance(minutes=55)
    assert request_code(client, "aditi@uw.edu").status_code == 200


def test_requests_are_limited_per_ip_address(settings, clock, mailer: RecordingMailer) -> None:
    from app.deps import get_now
    from app.main import create_app

    app = create_app(settings.model_copy(update={"code_requests_per_ip_per_hour": 3}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        statuses = [request_code(client, f"student{n}@uw.edu").status_code for n in range(4)]

    assert statuses == [200, 200, 200, 429]
    assert len(mailer.sent) == 3


def test_verify_attempts_are_limited_per_ip_address(
    settings, clock, mailer: RecordingMailer
) -> None:
    from app.deps import get_now
    from app.main import create_app

    app = create_app(settings.model_copy(update={"verify_attempts_per_ip_per_hour": 2}))
    app.state.email_sender = mailer
    app.dependency_overrides[get_now] = lambda: clock.now
    with TestClient(app) as client:
        statuses = [verify(client, f"student{n}@uw.edu", "000000").status_code for n in range(3)]

    assert statuses == [400, 400, 429]


def test_a_refused_request_does_not_use_up_the_limit(client: TestClient, db: Session) -> None:
    for _ in range(10):
        request_code(client, "aditi@gmail.com")

    assert db.scalar(select(func.count()).select_from(RateLimitHit)) == 0


# --- Dependency unavailable: the email provider ------------------------------


def test_email_provider_down_gives_a_clear_error_and_keeps_nothing(
    client: TestClient, mailer: RecordingMailer, db: Session
) -> None:
    mailer.down = True

    response = request_code(client, "aditi@uw.edu")

    assert response.status_code == 503
    assert response.json() == {
        "code": "email_unavailable",
        "message": "We couldn't send your code just now. Try again in a minute.",
    }
    assert response.headers["Retry-After"] == "60"
    # No code the student never received, and no strike against their limit.
    assert db.scalar(select(func.count()).select_from(EmailCode)) == 0
    assert db.scalar(select(func.count()).select_from(RateLimitHit)) == 0


def test_sign_up_works_as_soon_as_the_email_provider_is_back(
    client: TestClient, mailer: RecordingMailer
) -> None:
    mailer.down = True
    for _ in range(6):  # more failures than the hourly limit
        assert request_code(client, "aditi@uw.edu").status_code == 503

    mailer.down = False

    assert sign_in(client, mailer, "aditi@uw.edu")["user"]["verified"] is True


def test_signed_in_students_are_not_affected_when_the_email_provider_is_down(
    client: TestClient, mailer: RecordingMailer, aditi: dict
) -> None:
    mailer.down = True

    assert client.get("/v1/me", headers=bearer(aditi)).status_code == 200
    refreshed = client.post(REFRESH, json={"refresh_token": aditi["refresh_token"]})
    assert refreshed.status_code == 200


def test_smtp_sender_reports_an_unreachable_server_as_unavailable(settings) -> None:
    from app.services.email_sender import EmailUnavailable, SmtpEmailSender

    sender = SmtpEmailSender(
        settings.model_copy(
            update={
                "email_backend": "smtp",
                "smtp_host": "127.0.0.1",
                "smtp_port": 1,  # nothing listens here
                "smtp_timeout_s": 2,
            }
        )
    )

    with pytest.raises(EmailUnavailable):
        sender.send_code("aditi@uw.edu", "123456", 10)


class FakeSmtpServer:
    """A tiny SMTP server on localhost that records what it is sent."""

    def __init__(self) -> None:
        import socketserver
        import threading

        outer = self
        self.messages: list[str] = []
        self.recipients: list[str] = []

        class Handler(socketserver.StreamRequestHandler):
            def handle(self) -> None:
                self.wfile.write(b"220 fake ESMTP\r\n")
                while line := self.rfile.readline():
                    command = line.decode().strip()
                    upper = command.upper()
                    if upper.startswith(("EHLO", "HELO")):
                        self.wfile.write(b"250 fake\r\n")
                    elif upper.startswith("RCPT TO"):
                        outer.recipients.append(command.split(":", 1)[1].strip(" <>"))
                        self.wfile.write(b"250 OK\r\n")
                    elif upper == "DATA":
                        self.wfile.write(b"354 go ahead\r\n")
                        data = b""
                        while not data.endswith(b"\r\n.\r\n"):
                            data += self.rfile.readline()
                        outer.messages.append(data.decode())
                        self.wfile.write(b"250 queued\r\n")
                    elif upper == "QUIT":
                        self.wfile.write(b"221 bye\r\n")
                        return
                    else:
                        self.wfile.write(b"250 OK\r\n")

        self._server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self._server.daemon_threads = True
        self.port = self._server.server_address[1]
        threading.Thread(target=self._server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()


def test_smtp_sender_delivers_the_code_to_a_real_smtp_conversation(settings) -> None:
    from app.services.email_sender import SmtpEmailSender, make_email_sender

    server = FakeSmtpServer()
    try:
        smtp_settings = settings.model_copy(
            update={
                "email_backend": "smtp",
                "email_from": "Sublette <verify@sublette.example>",
                "smtp_host": "127.0.0.1",
                "smtp_port": server.port,
                "smtp_security": "none",
            }
        )
        sender = make_email_sender(smtp_settings)
        assert isinstance(sender, SmtpEmailSender)

        sender.send_code("aditi@uw.edu", "482913", 10)
    finally:
        server.close()

    assert server.recipients == ["aditi@uw.edu"]
    message = server.messages[0]
    assert "Subject: 482913 is your Sublette code" in message
    assert "From: Sublette <verify@sublette.example>" in message
    assert "To: aditi@uw.edu" in message
    assert "482913" in message.split("\r\n\r\n", 1)[1]
    assert "10 minutes" in message


def test_console_sender_writes_the_code_to_the_log(caplog) -> None:
    import logging

    from app.services.email_sender import ConsoleEmailSender

    with caplog.at_level(logging.INFO, logger="sublette.email"):
        ConsoleEmailSender().send_code("aditi@uw.edu", "123456", 10)

    assert "aditi@uw.edu" in caplog.text
    assert "123456" in caplog.text


# --- Tokens -------------------------------------------------------------------


def test_the_access_token_opens_the_account(client: TestClient, aditi: dict) -> None:
    response = client.get("/v1/me", headers=bearer(aditi))

    assert response.status_code == 200
    assert response.json()["email"] == "aditi@uw.edu"


def test_the_access_token_expires_after_fifteen_minutes(
    client: TestClient, aditi: dict, clock: Clock
) -> None:
    clock.advance(minutes=14, seconds=59)
    assert client.get("/v1/me", headers=bearer(aditi)).status_code == 200

    clock.advance(seconds=1)
    expired = client.get("/v1/me", headers=bearer(aditi))

    assert expired.status_code == 401
    assert expired.json()["code"] == "token_expired"


def test_refresh_returns_new_tokens_that_work(
    client: TestClient, aditi: dict, clock: Clock
) -> None:
    clock.advance(days=20)

    response = client.post(REFRESH, json={"refresh_token": aditi["refresh_token"]})

    assert response.status_code == 200
    fresh = response.json()
    assert fresh["access_token"] != aditi["access_token"]
    assert fresh["expires_in"] == 15 * 60
    assert client.get("/v1/me", headers=bearer(fresh)).status_code == 200


def test_the_refresh_token_expires_after_sixty_days(
    client: TestClient, aditi: dict, clock: Clock
) -> None:
    clock.advance(days=60)

    response = client.post(REFRESH, json={"refresh_token": aditi["refresh_token"]})

    assert response.status_code == 401
    assert response.json()["code"] == "token_expired"


def test_a_refresh_token_cannot_be_used_as_an_access_token(client: TestClient, aditi: dict) -> None:
    response = client.get("/v1/me", headers={"Authorization": f"Bearer {aditi['refresh_token']}"})

    assert response.status_code == 401
    assert response.json()["code"] == "token_invalid"


def test_an_access_token_cannot_be_used_to_refresh(client: TestClient, aditi: dict) -> None:
    response = client.post(REFRESH, json={"refresh_token": aditi["access_token"]})

    assert response.status_code == 401
    assert response.json()["code"] == "token_invalid"


@pytest.mark.parametrize(
    "header",
    ["", "Bearer", "Bearer ", "Token abc", "abc"],
)
def test_a_missing_or_malformed_header_is_not_signed_in(client: TestClient, header: str) -> None:
    response = client.get("/v1/me", headers={"Authorization": header} if header else {})

    assert response.status_code == 401
    assert response.json()["code"] == "not_signed_in"


def test_a_tampered_or_foreign_token_is_refused(
    client: TestClient, aditi: dict, settings, clock: Clock
) -> None:
    from app.services.tokens import issue_pair

    tampered = aditi["access_token"][:-3] + "abc"
    other_server = settings.model_copy(update={"secret_key": "another-server-secret-" * 3})
    foreign = issue_pair(other_server, aditi["user"]["id"], clock.now).access_token

    for token in (tampered, foreign, "not.a.token", "x"):
        response = client.get("/v1/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 401
        assert response.json()["code"] == "token_invalid"


def test_a_suspension_takes_effect_on_the_next_request(
    client: TestClient, aditi: dict, db: Session
) -> None:
    db.scalars(select(User)).one().status = "suspended"
    db.commit()

    response = client.get("/v1/me", headers=bearer(aditi))
    refresh = client.post(REFRESH, json={"refresh_token": aditi["refresh_token"]})

    assert response.status_code == 403
    assert response.json()["code"] == "account_suspended"
    assert refresh.status_code == 403


def test_token_lifetimes_follow_the_settings(settings, clock: Clock) -> None:
    from app.services.tokens import issue_pair, read_token

    short = settings.model_copy(update={"access_token_minutes": 1})
    pair = issue_pair(short, "00000000-0000-0000-0000-000000000001", clock.now)

    assert pair.expires_in == 60
    read_token(short, pair.access_token, "access", clock.now + timedelta(seconds=59))
