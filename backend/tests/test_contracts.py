"""The server, the iPhone app and the docs must agree.

These tests read files from all three places. They are what catches a path or
a color changed in one codebase and forgotten in another.
"""

import json
import re
import uuid

import pytest
from fastapi import FastAPI

from tests.conftest import REPO_ROOT

CONTRACT = REPO_ROOT / "docs" / "contract"
IOS_APP = REPO_ROOT / "ios" / "Sublette"
ENDPOINT_SWIFT = IOS_APP / "Core" / "Networking" / "Endpoint.swift"
BRAND_SWIFT = IOS_APP / "Core" / "DesignSystem" / "BrandColors.swift"

WCAG_BODY_TEXT = 4.5
HTTP_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}


def contract_entries() -> list[dict]:
    return json.loads((CONTRACT / "endpoints.json").read_text())["endpoints"]


PLACEHOLDER = re.compile(r"\{[^}]*\}|\\\([^)]*\)")


def shape(path: str) -> str:
    """`/v1/listings/{listing_id}` here and `/v1/listings/\\(id)` in Swift both
    become `/v1/listings/{}`."""
    return PLACEHOLDER.sub("{}", path)


def contract_endpoints() -> set[tuple[str, str]]:
    return {(item["method"], item["path"]) for item in contract_entries()}


def http_endpoints() -> set[tuple[str, str]]:
    """Every endpoint except the WebSocket, which OpenAPI doesn't list."""
    return {
        (item["method"], item["path"]) for item in contract_entries() if not item.get("websocket")
    }


def design_tokens() -> dict:
    return json.loads((CONTRACT / "design-tokens.json").read_text())


# --- Endpoints ---------------------------------------------------------------


def test_server_routes_match_the_contract(app: FastAPI) -> None:
    # The OpenAPI schema lists every route the server answers, including those
    # added through routers.
    served = {
        (method.upper(), path)
        for path, operations in app.openapi()["paths"].items()
        for method in operations
        if method.upper() in HTTP_METHODS
    }

    assert served == http_endpoints()


WEBSOCKETS = [item for item in contract_entries() if item.get("websocket")]


@pytest.mark.parametrize("item", WEBSOCKETS, ids=lambda item: item["path"])
def test_websockets_exist_and_refuse_a_connection_with_no_token(item: dict, client) -> None:
    """A WebSocket path the server doesn't have closes with 1000-range codes
    before accepting; ours accepts and then closes with 4401."""
    from starlette.websockets import WebSocketDisconnect

    with pytest.raises(WebSocketDisconnect) as closed, client.websocket_connect(item["path"]) as ws:
        ws.receive_json()

    assert closed.value.code == 4401
    assert closed.value.reason == "not_signed_in"


def test_every_path_except_health_is_under_v1() -> None:
    for item in contract_entries():
        if item.get("own_storage_only") or item.get("page"):
            continue
        assert item["path"] == "/health" or item["path"].startswith("/v1/"), item["path"]


def test_only_sign_in_and_health_are_open_to_everyone() -> None:
    open_paths = {
        item["path"]
        for item in contract_entries()
        if not item["auth"] and not item.get("own_storage_only") and not item.get("page")
    }

    assert open_paths == {
        "/health",
        "/v1/auth/request-code",
        "/v1/auth/verify",
        "/v1/auth/refresh",
    }


AUTH_ENDPOINTS = [
    item
    for item in json.loads((CONTRACT / "endpoints.json").read_text())["endpoints"]
    if item["auth"] and not item.get("websocket")
]


@pytest.mark.parametrize(
    "item", AUTH_ENDPOINTS, ids=lambda item: f"{item['method']} {item['path']}"
)
def test_endpoints_marked_auth_refuse_a_request_with_no_token(item: dict, client) -> None:
    """Every endpoint except sign-in requires a verified account."""
    path = PLACEHOLDER.sub(str(uuid.uuid4()), item["path"])
    response = client.request(item["method"], path, json={})

    assert response.status_code == 401
    assert response.json()["code"] == "not_signed_in"


def test_file_routes_are_served_only_when_this_server_stores_photos(settings) -> None:
    from app.main import create_app

    def has_file_routes(backend: str) -> bool:
        app = create_app(settings.model_copy(update={"storage_backend": backend}))
        return any(path.startswith("/files") for path in app.openapi()["paths"])

    assert has_file_routes("local")
    assert has_file_routes("database")
    assert not has_file_routes("none")


def swift_endpoints() -> set[tuple[str, str]]:
    source = ENDPOINT_SWIFT.read_text()
    declared = re.findall(r'Endpoint\(\s*method:\s*\.(\w+),\s*path:\s*"([^"]+)"', source)
    return {(method.upper(), path) for method, path in declared}


def test_ios_endpoints_exist_on_the_server() -> None:
    declared = swift_endpoints()

    assert declared, "No endpoints found in Endpoint.swift; has its format changed?"
    contract = {(method, shape(path)) for method, path in contract_endpoints()}
    assert {(method, shape(path)) for method, path in declared} <= contract


def test_ios_declares_paths_only_in_endpoint_swift() -> None:
    """A path typed into a screen or view model would dodge the check above."""
    offenders = [
        str(path.relative_to(REPO_ROOT))
        for path in IOS_APP.rglob("*.swift")
        if path != ENDPOINT_SWIFT and re.search(r'path:\s*"/', path.read_text())
    ]

    assert offenders == []


# --- Colors ------------------------------------------------------------------


def _luminance(hex_color: str) -> float:
    channels = [int(hex_color.lstrip("#")[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first: str, second: str) -> float:
    lighter, darker = sorted((_luminance(first), _luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def _hex(name: str) -> str:
    return {"white": "#FFFFFF", **design_tokens()["colors"]}[name]


def test_ios_palette_matches_the_tokens() -> None:
    declared = dict(
        re.findall(r"static let (\w+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)", BRAND_SWIFT.read_text())
    )

    assert {name: f"#{value.upper()}" for name, value in declared.items()} == design_tokens()[
        "colors"
    ]


@pytest.mark.parametrize("pair", design_tokens()["text_pairs_allowed"], ids=lambda p: str(p))
def test_allowed_text_pairs_pass_wcag_and_match_the_spec(pair: dict) -> None:
    ratio = contrast(_hex(pair["text"]), _hex(pair["background"]))

    assert ratio >= WCAG_BODY_TEXT
    assert round(ratio, 1) == pair["spec_ratio"]


@pytest.mark.parametrize("pair", design_tokens()["text_pairs_forbidden"], ids=lambda p: str(p))
def test_forbidden_text_pairs_really_do_fail_wcag(pair: dict) -> None:
    assert contrast(_hex(pair["text"]), _hex(pair["background"])) < WCAG_BODY_TEXT


def test_ios_never_puts_white_text_on_yellow_or_orange() -> None:
    source = BRAND_SWIFT.read_text()

    # Palette.ink, not Brand.ink, which turns cream in dark mode.
    assert re.search(r"static let textOnYellow = Palette\.ink\b", source)
    assert re.search(r"static let textOnOrange = Palette\.ink\b", source)
