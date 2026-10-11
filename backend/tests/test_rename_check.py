"""Tests for scripts/check_renames.py, the tool behind `make check` and `make find-refs`."""

import importlib.util
import sys
from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT

_spec = importlib.util.spec_from_file_location(
    "check_renames", REPO_ROOT / "scripts" / "check_renames.py"
)
check_renames = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = check_renames
_spec.loader.exec_module(check_renames)


def write(root: Path, relative: str, content: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def registry(*, keep: str = "", no_test: str = "") -> str:
    return (
        "[[rename]]\n"
        'old = "/v1/deck"\n'
        'new = "/v1/deck/listings"\n'
        f"keep = [{keep}]\n"
        f'no_test = "{no_test}"\n'
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    write(tmp_path, "docs/renames.toml", registry())
    write(tmp_path, "backend/tests/test_deck.py", 'client.get("/v1/deck/listings")\n')
    return tmp_path


def test_a_clean_repository_passes(repo: Path) -> None:
    assert check_renames.check(repo) == []


@pytest.mark.parametrize(
    "stale_file",
    [
        "backend/app/routers/deck.py",
        "backend/tests/fixtures/deck.json",
        "backend/scripts/seed.py",
        "ios/Sublette/Core/Networking/Endpoint.swift",
        "ios/SubletteTests/EndpointTests.swift",
        "docs/api.md",
        ".github/workflows/ci.yml",
        "firestore.rules",
    ],
)
def test_an_old_name_left_anywhere_fails(repo: Path, stale_file: str) -> None:
    write(repo, stale_file, 'first line\n  path = "/v1/deck"  # comment\n')

    problems = check_renames.check(repo)

    assert len(problems) == 1
    assert problems[0].startswith(f"{stale_file}:2:")


def test_an_old_name_in_a_comment_fails(repo: Path) -> None:
    write(repo, "backend/app/routers/deck.py", "# was /v1/deck before phase 5\n")

    assert len(check_renames.check(repo)) == 1


def test_the_new_name_is_not_mistaken_for_the_old_one(repo: Path) -> None:
    write(repo, "backend/app/routers/deck.py", 'PATH = "/v1/deck/listings"\n')

    assert check_renames.check(repo) == []


def test_a_deliberately_kept_occurrence_passes(repo: Path) -> None:
    write(
        repo,
        "docs/renames.toml",
        registry(keep='{ path = "backend/alembic/versions/*.py", why = "history" }'),
    )
    write(repo, "backend/alembic/versions/0002_rename.py", "# renames /v1/deck\n")

    assert check_renames.check(repo) == []


def test_a_keep_without_a_reason_is_rejected(repo: Path) -> None:
    write(repo, "docs/renames.toml", registry(keep='{ path = "docs/*.md" }'))

    with pytest.raises(ValueError, match="why"):
        check_renames.check(repo)


def test_a_rename_with_no_test_for_the_new_name_fails(repo: Path) -> None:
    (repo / "backend/tests/test_deck.py").unlink()
    write(repo, "backend/app/routers/deck.py", 'PATH = "/v1/deck/listings"\n')

    problems = check_renames.check(repo)

    assert len(problems) == 1
    assert "does not appear in any test" in problems[0]


def test_no_test_needs_a_stated_reason_to_be_skipped(repo: Path) -> None:
    (repo / "backend/tests/test_deck.py").unlink()
    write(repo, "docs/renames.toml", registry(no_test="file rename only"))

    assert check_renames.check(repo) == []


@pytest.mark.parametrize(
    ("line", "old", "expected"),
    [
        ("radius = pin.radius_m", "pin", True),
        ("show(spinner)", "pin", False),
        ("pin_color = yellow", "pin", False),
        ('"rent": 1200', "rent", True),
        ("rent_cents = 120000", "rent", False),
        ("GET /v1/deck?limit=20", "/v1/deck", True),
        ("GET /v1/decks", "/v1/deck", False),
    ],
)
def test_matches_whole_names_only(line: str, old: str, expected: bool) -> None:
    assert check_renames.find_in_line(line, old) is expected


def test_find_lists_every_occurrence_with_its_line(repo: Path) -> None:
    write(repo, "docs/api.md", "intro\nGET /v1/deck/listings\n")

    found = check_renames.find_occurrences(repo, "/v1/deck/listings")

    assert {(item.path, item.line_number) for item in found} >= {
        ("docs/api.md", 2),
        ("backend/tests/test_deck.py", 1),
    }


def test_binary_and_ignored_folders_are_skipped(repo: Path) -> None:
    (repo / "photo.jpg").write_bytes(b"\xff\xd8\0\0/v1/deck")
    write(repo, "backend/.venv/lib/site.py", '"/v1/deck"\n')
    write(repo, "ios/Sublette.xcodeproj/project.pbxproj", '"/v1/deck"\n')

    assert check_renames.check(repo) == []


def test_areas_are_named_for_the_find_report() -> None:
    assert check_renames.area_of("backend/alembic/versions/0001.py") == "Server migrations"
    assert check_renames.area_of("backend/tests/test_x.py") == "Server tests and fixtures"
    assert check_renames.area_of("ios/SubletteTests/A.swift") == "iPhone tests"
    assert check_renames.area_of("README.md") == "Everything else"


def test_this_repository_has_no_stale_names() -> None:
    assert check_renames.check(REPO_ROOT) == []
