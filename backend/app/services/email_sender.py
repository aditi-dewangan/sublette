"""Sending the sign-in code. The provider is a setting, not a code change."""

import json
import logging
import smtplib
import ssl
import urllib.error
import urllib.request
from email.message import EmailMessage
from email.utils import parseaddr
from typing import Protocol

from app.config import Settings

logger = logging.getLogger("sublette.email")


class EmailUnavailable(Exception):
    """The email provider could not be reached or refused the message."""


class EmailSender(Protocol):
    def send_code(self, to: str, code: str, ttl_minutes: int) -> None:
        """Send the code, or raise EmailUnavailable."""


class ConsoleEmailSender:
    """Development: print the code in the server log instead of sending it."""

    def send_code(self, to: str, code: str, ttl_minutes: int) -> None:
        logger.info("Sign-in code for %s: %s (valid %d minutes)", to, code, ttl_minutes)


def _body_text(code: str, ttl_minutes: int) -> str:
    return (
        f"Your Sublette code is {code}\n\n"
        f"It works for {ttl_minutes} minutes. Enter it in the app to verify your "
        "school email.\n\n"
        "If you didn't ask for this, you can ignore this email. Nobody can sign "
        "in without the code.\n"
    )


def _subject(code: str) -> str:
    return f"{code} is your Sublette code"


class SmtpEmailSender:
    """Any provider that speaks SMTP: Resend, Postmark, Amazon SES and others."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def _message(self, to: str, code: str, ttl_minutes: int) -> EmailMessage:
        message = EmailMessage()
        message["From"] = self._settings.email_from
        message["To"] = to
        message["Subject"] = _subject(code)
        message.set_content(_body_text(code, ttl_minutes))
        return message

    def send_code(self, to: str, code: str, ttl_minutes: int) -> None:
        settings = self._settings
        try:
            if settings.smtp_security == "ssl":
                server: smtplib.SMTP = smtplib.SMTP_SSL(
                    settings.smtp_host,
                    settings.smtp_port,
                    timeout=settings.smtp_timeout_s,
                    context=ssl.create_default_context(),
                )
            else:
                server = smtplib.SMTP(
                    settings.smtp_host, settings.smtp_port, timeout=settings.smtp_timeout_s
                )
            with server:
                if settings.smtp_security == "starttls":
                    server.starttls(context=ssl.create_default_context())
                if settings.smtp_username:
                    server.login(settings.smtp_username, settings.smtp_password)
                server.send_message(self._message(to, code, ttl_minutes))
        except (OSError, smtplib.SMTPException) as error:
            # OSError covers refused connections, DNS failures and timeouts.
            logger.warning("Could not send sign-in email: %s", type(error).__name__)
            raise EmailUnavailable(type(error).__name__) from error


class BrevoEmailSender:
    """Brevo's transactional email API, over HTTPS.

    Free plan: 300 emails a day, no card needed. Works where outgoing SMTP is
    blocked. The sender address must first be verified in Brevo.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def _payload(self, to: str, code: str, ttl_minutes: int) -> bytes:
        name, address = parseaddr(self._settings.email_from)
        return json.dumps(
            {
                "sender": {"name": name or "Sublette", "email": address},
                "to": [{"email": to}],
                "subject": _subject(code),
                "textContent": _body_text(code, ttl_minutes),
            }
        ).encode()

    def send_code(self, to: str, code: str, ttl_minutes: int) -> None:
        request = urllib.request.Request(
            self._settings.brevo_api_url,
            data=self._payload(to, code, ttl_minutes),
            method="POST",
            headers={
                "api-key": self._settings.brevo_api_key,
                "content-type": "application/json",
                "accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self._settings.email_timeout_s) as reply:
                status = reply.status
        except urllib.error.HTTPError as error:
            # Brevo answered with an error: a wrong key, an unverified sender,
            # the daily limit reached. The reason is in the body; log it, never
            # the key.
            detail = error.read(500).decode("utf-8", "replace")
            logger.warning("Brevo refused the sign-in email (%s): %s", error.code, detail)
            raise EmailUnavailable(f"brevo {error.code}") from error
        except (OSError, ValueError) as error:
            # Refused connection, DNS failure, timeout, TLS failure.
            logger.warning("Could not reach Brevo: %s", type(error).__name__)
            raise EmailUnavailable(type(error).__name__) from error
        if not 200 <= status < 300:
            logger.warning("Brevo answered %s to the sign-in email", status)
            raise EmailUnavailable(f"brevo {status}")


def make_email_sender(settings: Settings) -> EmailSender:
    if settings.email_backend == "smtp":
        return SmtpEmailSender(settings)
    if settings.email_backend == "brevo":
        return BrevoEmailSender(settings)
    return ConsoleEmailSender()
