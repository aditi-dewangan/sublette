"""The server, the iPhone app and the docs must agree.

These tests read files from all three places. They are what catches a path or
a color changed in one codebase and forgotten in another.
"""

import json
import re

import pytest
from fastapi import FastAPI

from tests.conftest import REPO_ROOT

CONTRACT = REPO_ROOT / "docs" / "contract"
IOS_APP = REPO_ROOT / "ios" / "Sublette"
ENDPOINT_SWIFT = IOS_APP / "Core" / "Networking" / "Endpoint.swift"
BRAND_SWIFT = IOS_APP / "Core" / "DesignSystem" / "BrandColors.swift"

WCAG_BODY_TEXT = 4.5
HTTP_METHODS = {"GET", "POST", "PUT", "PATCH", "DELETE"}


def contract_endpoints() -> set[tuple[str, str]]:
    data = json.loads((CONTRACT / "endpoints.json").read_text())
    return {(item["method"], item["path"]) for item in data["endpoints"]}


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

    assert served == contract_endpoints()


def test_every_path_except_health_is_under_v1() -> None:
    for _, path in contract_endpoints():
        assert path == "/health" or path.startswith("/v1/"), path


def swift_endpoints() -> set[tuple[str, str]]:
    source = ENDPOINT_SWIFT.read_text()
    declared = re.findall(r'Endpoint\(\s*method:\s*\.(\w+),\s*path:\s*"([^"]+)"', source)
    return {(method.upper(), path) for method, path in declared}


def test_ios_endpoints_exist_on_the_server() -> None:
    declared = swift_endpoints()

    assert declared, "No endpoints found in Endpoint.swift; has its format changed?"
    assert declared <= contract_endpoints()


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

    assert re.search(r"static let textOnYellow = ink\b", source)
    assert re.search(r"static let textOnOrange = ink\b", source)
