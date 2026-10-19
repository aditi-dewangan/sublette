"""The Apple Push Notification service sender, against a stand-in for Apple."""

import json

import httpx2
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import Settings
from app.services.push import (
    ApnsPushSender,
    LogPushSender,
    NoPushSender,
    PushNote,
    PushUnavailable,
    make_push_sender,
)

TOKEN = "ab" * 32
NOTE = PushNote(
    title="Sam", body="Is parking included?", data={"kind": "message", "match_id": "m1"}
)


@pytest.fixture(scope="module")
def key_pair() -> tuple[str, ec.EllipticCurvePublicKey]:
    private = ec.generate_private_key(ec.SECP256R1())
    pem = private.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return pem, private.public_key()


def apns_settings(pem: str, **changes) -> Settings:
    values = dict(
        env="test",
        push_backend="apns",
        apns_team_id="TEAM123456",
        apns_key_id="KEY1234567",
        apns_private_key=pem,
    )
    values.update(changes)
    return Settings(**values)


class Apple:
    """Answers like APNs, or like a broken one."""

    def __init__(self, status: int = 200, body: bytes = b"", error: Exception | None = None):
        self.status = status
        self.body = body
        self.error = error
        self.requests: list[httpx2.Request] = []

    def __call__(self, request: httpx2.Request) -> httpx2.Response:
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return httpx2.Response(self.status, content=self.body)


def sender_for(pem: str, apple: Apple, **changes) -> ApnsPushSender:
    client = httpx2.Client(transport=httpx2.MockTransport(apple))
    return ApnsPushSender(apns_settings(pem, **changes), client=client)


def test_a_notification_is_signed_and_addressed_as_apple_expects(key_pair) -> None:
    pem, public = key_pair
    apple = Apple()

    assert sender_for(pem, apple).send(TOKEN, "sandbox", NOTE) == "sent"

    [request] = apple.requests
    assert str(request.url) == f"https://api.sandbox.push.apple.com/3/device/{TOKEN}"
    assert request.headers["apns-topic"] == "app.sublette.Sublette"
    assert request.headers["apns-push-type"] == "alert"
    scheme, _, token = request.headers["authorization"].partition(" ")
    assert scheme == "bearer"
    assert jwt.get_unverified_header(token)["kid"] == "KEY1234567"
    assert jwt.decode(token, public, algorithms=["ES256"])["iss"] == "TEAM123456"
    payload = json.loads(request.content)
    assert payload["aps"]["alert"] == {"title": "Sam", "body": "Is parking included?"}
    assert payload["aps"]["thread-id"] == "m1"
    assert payload["match_id"] == "m1"


def test_production_tokens_go_to_the_production_server(key_pair) -> None:
    apple = Apple()

    sender_for(key_pair[0], apple).send(TOKEN, "production", NOTE)

    assert apple.requests[0].url.host == "api.push.apple.com"


def test_the_signing_token_is_reused(key_pair) -> None:
    apple = Apple()
    sender = sender_for(key_pair[0], apple)

    sender.send(TOKEN, "sandbox", NOTE)
    sender.send(TOKEN, "sandbox", NOTE)

    first, second = (request.headers["authorization"] for request in apple.requests)
    assert first == second, "Apple throttles providers that make a new one every time"


@pytest.mark.parametrize(
    ("status", "reason"),
    [(410, "Unregistered"), (400, "BadDeviceToken"), (400, "DeviceTokenNotForTopic")],
)
def test_a_phone_that_is_gone_is_reported(key_pair, status: int, reason: str) -> None:
    apple = Apple(status, json.dumps({"reason": reason}).encode())

    assert sender_for(key_pair[0], apple).send(TOKEN, "sandbox", NOTE) == "unregistered"


def test_apple_down_is_a_clear_failure(key_pair) -> None:
    apple = Apple(error=httpx2.ConnectError("refused"))

    with pytest.raises(PushUnavailable):
        sender_for(key_pair[0], apple).send(TOKEN, "sandbox", NOTE)


def test_apple_slow_times_out(key_pair) -> None:
    apple = Apple(error=httpx2.ReadTimeout("slow"))

    with pytest.raises(PushUnavailable):
        sender_for(key_pair[0], apple).send(TOKEN, "sandbox", NOTE)


@pytest.mark.parametrize("body", [b"<html>502 Bad Gateway</html>", b"", b"[1, 2]"])
def test_apple_answering_garbage_is_a_clear_failure(key_pair, body: bytes) -> None:
    apple = Apple(502, body)

    with pytest.raises(PushUnavailable):
        sender_for(key_pair[0], apple).send(TOKEN, "sandbox", NOTE)


def test_an_expired_signing_token_is_made_again_next_time(key_pair) -> None:
    apple = Apple(403, json.dumps({"reason": "ExpiredProviderToken"}).encode())
    sender = sender_for(key_pair[0], apple)

    with pytest.raises(PushUnavailable):
        sender.send(TOKEN, "sandbox", NOTE)

    assert sender._provider_token is None


def test_a_broken_key_is_a_clear_failure(key_pair) -> None:
    apple = Apple()

    with pytest.raises(PushUnavailable):
        sender_for("not a key", apple).send(TOKEN, "sandbox", NOTE)
    assert apple.requests == [], "nothing is sent without a signature"


def test_the_key_can_be_a_file(key_pair, tmp_path) -> None:
    path = tmp_path / "AuthKey.p8"
    path.write_text(key_pair[0])
    apple = Apple()

    sender = sender_for("", apple, apns_private_key_path=str(path))

    assert sender.send(TOKEN, "sandbox", NOTE) == "sent"


def test_a_key_pasted_on_one_line_still_works(key_pair) -> None:
    one_line = key_pair[0].replace("\n", "\\n")

    assert sender_for(one_line, Apple()).send(TOKEN, "sandbox", NOTE) == "sent"


def test_apns_needs_its_settings() -> None:
    with pytest.raises(ValueError) as refused:
        Settings(env="test", push_backend="apns")

    for name in ("SUBLETTE_APNS_TEAM_ID", "SUBLETTE_APNS_KEY_ID", "SUBLETTE_APNS_PRIVATE_KEY"):
        assert name in str(refused.value)


def test_the_default_prints_pushes_in_the_terminal(caplog) -> None:
    sender = make_push_sender(Settings(env="test"))

    with caplog.at_level("INFO", logger="sublette.push"):
        assert sender.send(TOKEN, "sandbox", NOTE) == "sent"

    assert isinstance(sender, LogPushSender)
    assert "Is parking included?" in caplog.text
    assert TOKEN not in caplog.text, "only the start of the token is logged"


def test_push_can_be_turned_off() -> None:
    assert isinstance(make_push_sender(Settings(env="test", push_backend="none")), NoPushSender)
