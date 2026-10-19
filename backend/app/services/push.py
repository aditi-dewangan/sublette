"""Push notifications through Apple Push Notification service (APNs).

The provider is a setting: "log" prints each notification in the server's
terminal (the default, so `make dev` needs nothing), "apns" sends for real,
"none" sends nothing.

Pushes never hold up a request. Routes hand them to `PushDispatcher`, which
sends on its own threads after the change is committed. Apple being down,
slow or answering nonsense is logged and dropped: the message is already
saved and shows the next time the app opens.
"""

import json
import logging
import time
import uuid
from collections.abc import Callable
from concurrent.futures import Future, ThreadPoolExecutor, wait
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal, Protocol

import httpx2
import jwt
from sqlalchemy import Engine, delete, select
from sqlalchemy.orm import Session

from app.config import Settings
from app.models import DeviceToken

logger = logging.getLogger("sublette.push")

APNS_HOSTS = {
    "sandbox": "https://api.sandbox.push.apple.com",
    "production": "https://api.push.apple.com",
}
# Apple refuses provider tokens older than an hour and throttles new ones made
# more often than every 20 minutes.
PROVIDER_TOKEN_LIFE_S = 50 * 60
# Apple's reasons that mean the token will never work again.
DEAD_TOKEN_REASONS = {"BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"}
PREVIEW_CHARACTERS = 120

Outcome = Literal["sent", "unregistered"]


class PushUnavailable(Exception):
    """Apple could not be reached, or refused for a reason other than the token."""


@dataclass(frozen=True)
class PushNote:
    title: str
    body: str
    # What the app needs to open the right screen: kind, match_id, role.
    data: dict = field(default_factory=dict)


class PushSender(Protocol):
    def send(self, token: str, environment: str, note: PushNote) -> Outcome:
        """Send one notification. Raises PushUnavailable."""


class LogPushSender:
    """Development default: print the notification instead of sending it."""

    def send(self, token: str, environment: str, note: PushNote) -> Outcome:
        logger.info("Push to phone %s…: %s: %s %s", token[:8], note.title, note.body, note.data)
        return "sent"


class NoPushSender:
    def send(self, token: str, environment: str, note: PushNote) -> Outcome:
        return "sent"


def preview(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= PREVIEW_CHARACTERS else text[: PREVIEW_CHARACTERS - 1] + "…"


class ApnsPushSender:
    """Apple's HTTP/2 API, signed with a .p8 key (token-based authentication)."""

    def __init__(self, settings: Settings, client: httpx2.Client | None = None) -> None:
        self._settings = settings
        self._client = client or httpx2.Client(http2=True, timeout=settings.push_timeout_s)
        self._provider_token: tuple[str, float] | None = None

    def _private_key(self) -> str:
        if self._settings.apns_private_key:
            return self._settings.apns_private_key.replace("\\n", "\n")
        return Path(self._settings.apns_private_key_path).read_text()

    def _authorization(self) -> str:
        now = time.time()
        if self._provider_token is None or now - self._provider_token[1] > PROVIDER_TOKEN_LIFE_S:
            try:
                token = jwt.encode(
                    {"iss": self._settings.apns_team_id, "iat": int(now)},
                    self._private_key(),
                    algorithm="ES256",
                    headers={"kid": self._settings.apns_key_id},
                )
            except (OSError, ValueError, jwt.PyJWTError) as error:
                logger.warning("The APNs key could not be read: %s", type(error).__name__)
                raise PushUnavailable("bad key") from error
            self._provider_token = (token, now)
        return f"bearer {self._provider_token[0]}"

    def send(self, token: str, environment: str, note: PushNote) -> Outcome:
        payload = {
            "aps": {
                "alert": {"title": note.title, "body": note.body},
                "sound": "default",
                # Groups a chat's notifications together on the lock screen.
                "thread-id": note.data.get("match_id", note.data.get("kind", "sublette")),
            },
            **note.data,
        }
        try:
            reply = self._client.post(
                f"{APNS_HOSTS[environment]}/3/device/{token}",
                content=json.dumps(payload).encode(),
                headers={
                    "authorization": self._authorization(),
                    "apns-topic": self._settings.apns_topic,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                },
            )
        except httpx2.HTTPError as error:
            # Refused connection, DNS failure, timeout, TLS failure.
            logger.warning("Could not reach APNs: %s", type(error).__name__)
            raise PushUnavailable(type(error).__name__) from error
        if reply.status_code == 200:
            return "sent"
        reason = _reason(reply)
        if reply.status_code == 410 or reason in DEAD_TOKEN_REASONS:
            return "unregistered"
        if reason in ("ExpiredProviderToken", "InvalidProviderToken"):
            self._provider_token = None
        logger.warning("APNs refused a notification (%s): %s", reply.status_code, reason)
        raise PushUnavailable(f"apns {reply.status_code} {reason}")


def _reason(reply: httpx2.Response) -> str:
    try:
        return str(reply.json().get("reason", "unknown"))
    except (ValueError, AttributeError):
        return "unreadable answer"


def make_push_sender(settings: Settings) -> PushSender:
    if settings.push_backend == "apns":
        return ApnsPushSender(settings)
    if settings.push_backend == "none":
        return NoPushSender()
    return LogPushSender()


class PushDispatcher:
    """Sends pushes on background threads, after the request has answered.

    `run` takes a job that receives a database session; jobs look up who to
    notify and call `deliver`. Tests call `drain` to wait for them.
    """

    def __init__(self, engine: Engine, sender: PushSender, workers: int = 4) -> None:
        self.engine = engine
        self.sender = sender
        self._pool = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="push")
        self._pending: set[Future] = set()

    def run(self, job: Callable[[Session], None]) -> None:
        future = self._pool.submit(self._run, job)
        self._pending.add(future)
        future.add_done_callback(self._pending.discard)

    def _run(self, job: Callable[[Session], None]) -> None:
        try:
            with Session(self.engine) as session:
                job(session)
        except Exception:
            # A push must never take anything else down with it.
            logger.exception("A push job failed")

    def deliver(self, session: Session, user_id: uuid.UUID, note: PushNote) -> int:
        """Send `note` to every phone of `user_id`. Returns how many took it."""
        devices = session.scalars(select(DeviceToken).where(DeviceToken.user_id == user_id)).all()
        sent = 0
        for device in devices:
            try:
                outcome = self.sender.send(device.token, device.environment, note)
            except PushUnavailable:
                continue
            except Exception:
                logger.exception("The push sender failed")
                continue
            if outcome == "unregistered":
                # The app was deleted or notifications were turned off for good.
                session.execute(delete(DeviceToken).where(DeviceToken.token == device.token))
                session.commit()
            else:
                sent += 1
        return sent

    def drain(self, timeout: float = 10) -> None:
        wait(list(self._pending), timeout=timeout)

    def shutdown(self) -> None:
        """Drop pushes not yet started; let the ones being sent finish."""
        self._pool.shutdown(wait=True, cancel_futures=True)
