"""The language models the assistant can use, behind one small interface.

* AnthropicModel: Claude over Anthropic's Messages API (needs a paid key).
* OllamaModel: a model running on the developer's own computer (free).

Both take a system prompt and a user message and return the model's text.
Anything that goes wrong (down, slow, refused, garbage) raises
ModelUnavailable, and the assistant falls back to Sublette's own rules.
"""

import logging
from typing import Protocol

import httpx2

from app.config import Settings

logger = logging.getLogger("sublette.assistant")


class ModelUnavailable(Exception):
    """The model couldn't answer usefully right now."""


class LanguageModel(Protocol):
    name: str

    def complete(self, system: str, user: str) -> str: ...


class AnthropicModel:
    name = "anthropic"

    def __init__(self, settings: Settings, client: httpx2.Client | None = None) -> None:
        self._settings = settings
        self._client = client or httpx2.Client(timeout=settings.assistant_timeout_s)

    def complete(self, system: str, user: str) -> str:
        try:
            reply = self._client.post(
                self._settings.anthropic_api_url,
                headers={
                    "x-api-key": self._settings.anthropic_api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": self._settings.anthropic_model,
                    "max_tokens": 1500,
                    "system": system,
                    "messages": [{"role": "user", "content": user}],
                },
            )
        except httpx2.HTTPError as error:
            raise ModelUnavailable(type(error).__name__) from error
        if reply.status_code != 200:
            raise ModelUnavailable(f"anthropic {reply.status_code}")
        try:
            blocks = reply.json()["content"]
            return "".join(block.get("text", "") for block in blocks if block.get("type") == "text")
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            raise ModelUnavailable("unreadable answer") from error


class OllamaModel:
    name = "ollama"

    def __init__(self, settings: Settings, client: httpx2.Client | None = None) -> None:
        self._settings = settings
        self._client = client or httpx2.Client(timeout=settings.assistant_timeout_s)

    def complete(self, system: str, user: str) -> str:
        try:
            reply = self._client.post(
                f"{self._settings.ollama_url.rstrip('/')}/api/chat",
                json={
                    "model": self._settings.ollama_model,
                    "stream": False,
                    "format": "json",
                    "messages": [
                        {"role": "system", "content": system},
                        {"role": "user", "content": user},
                    ],
                },
            )
        except httpx2.HTTPError as error:
            raise ModelUnavailable(type(error).__name__) from error
        if reply.status_code != 200:
            raise ModelUnavailable(f"ollama {reply.status_code}")
        try:
            return str(reply.json()["message"]["content"])
        except (ValueError, KeyError, TypeError) as error:
            raise ModelUnavailable("unreadable answer") from error


def make_language_model(settings: Settings) -> LanguageModel | None:
    """None means Sublette's own rules do everything."""
    if settings.assistant_backend == "anthropic":
        return AnthropicModel(settings)
    if settings.assistant_backend == "ollama":
        return OllamaModel(settings)
    return None
