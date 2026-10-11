#!/usr/bin/env python3
"""Find leftover references to renamed things.

Usage:
    python scripts/check_renames.py              check docs/renames.toml against the repo
    python scripts/check_renames.py find VALUE   list every place VALUE appears

See docs/renames.toml for the entry format. Needs Python 3.11 or later.
"""

from __future__ import annotations

import fnmatch
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

REGISTRY = "docs/renames.toml"

SKIP_DIRS = {
    ".git",
    ".venv",
    "venv",
    "node_modules",
    "__pycache__",
    ".pytest_cache",
    ".ruff_cache",
    "build",
    "dist",
    "DerivedData",
    ".build",
}
SKIP_DIR_SUFFIXES = (".xcodeproj", ".xcworkspace", ".egg-info", ".xcassets")

# First match wins. Used to group the output of `find`.
AREAS = [
    ("Server migrations", "backend/alembic/"),
    ("Server tests and fixtures", "backend/tests/"),
    ("Server code", "backend/"),
    ("iPhone tests", "ios/SubletteTests/"),
    ("iPhone app", "ios/"),
    ("Docs and contracts", "docs/"),
    ("Scripts", "scripts/"),
    ("CI", ".github/"),
]
TEST_DIRS = ("backend/tests/", "ios/SubletteTests/")

IDENTIFIER_CHAR = re.compile(r"[A-Za-z0-9_]")


@dataclass(frozen=True)
class Occurrence:
    path: str
    line_number: int
    line: str


@dataclass
class Rename:
    old: str
    new: str
    keep: list[dict[str, str]] = field(default_factory=list)
    no_test: str = ""


def repo_files(root: Path) -> list[str]:
    """Every text file in the repository, as paths relative to root.

    Uses git when it can, so .gitignore is respected. Falls back to walking the
    folder, for a copy that was downloaded as a zip.
    """
    try:
        output = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
            cwd=root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        candidates = [line for line in output.splitlines() if line]
    except (OSError, subprocess.CalledProcessError):
        candidates = [str(path.relative_to(root)) for path in root.rglob("*")]

    files = []
    for relative in candidates:
        parts = Path(relative).parts
        if any(part in SKIP_DIRS or part.endswith(SKIP_DIR_SUFFIXES) for part in parts[:-1]):
            continue
        if (root / relative).is_file():
            files.append(Path(relative).as_posix())
    return sorted(files)


def read_text(path: Path) -> str | None:
    """File contents, or None for a binary file."""
    data = path.read_bytes()
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _spans(needle: str, haystack: str) -> list[tuple[int, int]]:
    spans, start = [], haystack.find(needle)
    while start != -1:
        spans.append((start, start + len(needle)))
        start = haystack.find(needle, start + 1)
    return spans


def _is_whole(line: str, start: int, end: int, needle: str) -> bool:
    """True unless the match is the middle of a longer identifier.

    `pin` must not match inside `spinner`. A boundary is only required on a
    side where the needle itself begins or ends with an identifier character.
    """
    if IDENTIFIER_CHAR.match(needle[0]) and start > 0 and IDENTIFIER_CHAR.match(line[start - 1]):
        return False
    return not (
        IDENTIFIER_CHAR.match(needle[-1]) and end < len(line) and IDENTIFIER_CHAR.match(line[end])
    )


def find_in_line(line: str, old: str, new: str | None = None) -> bool:
    """Does this line still use `old`? Uses of `new` that contain `old` do not count."""
    new_spans = _spans(new, line) if new and old in new and new != old else []
    for start, end in _spans(old, line):
        if not _is_whole(line, start, end, old):
            continue
        if any(new_start <= start and end <= new_end for new_start, new_end in new_spans):
            continue
        return True
    return False


def find_occurrences(root: Path, old: str, new: str | None = None) -> list[Occurrence]:
    found = []
    for relative in repo_files(root):
        text = read_text(root / relative)
        if text is None or old not in text:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if find_in_line(line, old, new):
                found.append(Occurrence(relative, number, line.strip()))
    return found


def load_renames(root: Path) -> list[Rename]:
    registry = root / REGISTRY
    if not registry.exists():
        return []
    data = tomllib.loads(registry.read_text(encoding="utf-8"))
    renames = []
    for entry in data.get("rename", []):
        for key in ("old", "new"):
            if not entry.get(key):
                raise ValueError(f"{REGISTRY}: every [[rename]] needs a non-empty `{key}`")
        for kept in entry.get("keep", []):
            if not kept.get("path") or not kept.get("why"):
                raise ValueError(f"{REGISTRY}: every `keep` needs both `path` and `why`")
        renames.append(
            Rename(
                old=entry["old"],
                new=entry["new"],
                keep=entry.get("keep", []),
                no_test=entry.get("no_test", ""),
            )
        )
    return renames


def check(root: Path) -> list[str]:
    """Return a list of problems. Empty means the repository is clean."""
    problems = []
    for rename in load_renames(root):
        kept_globs = [kept["path"] for kept in rename.keep]
        for occurrence in find_occurrences(root, rename.old, rename.new):
            if occurrence.path == REGISTRY:
                continue
            if any(fnmatch.fnmatch(occurrence.path, glob) for glob in kept_globs):
                continue
            problems.append(
                f"{occurrence.path}:{occurrence.line_number}: still uses "
                f"`{rename.old}` (renamed to `{rename.new}`): {occurrence.line}"
            )
        if not rename.no_test:
            tested = any(
                occurrence.path.startswith(TEST_DIRS)
                for occurrence in find_occurrences(root, rename.new)
            )
            if not tested:
                problems.append(
                    f"`{rename.new}` (renamed from `{rename.old}`) does not appear in any "
                    f"test under {' or '.join(TEST_DIRS)}. Add a test for the new name, "
                    "or set `no_test` with the reason."
                )
    return problems


def area_of(path: str) -> str:
    for name, prefix in AREAS:
        if path.startswith(prefix):
            return name
    return "Everything else"


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parents[1]

    if len(argv) >= 2 and argv[0] == "find":
        value = argv[1]
        occurrences = find_occurrences(root, value)
        if not occurrences:
            print(f"`{value}` does not appear anywhere in the repository.")
            return 0
        by_area: dict[str, list[Occurrence]] = {}
        for occurrence in occurrences:
            by_area.setdefault(area_of(occurrence.path), []).append(occurrence)
        for name in [*(name for name, _ in AREAS), "Everything else"]:
            if name not in by_area:
                continue
            print(f"\n{name}")
            for occurrence in by_area[name]:
                print(f"  {occurrence.path}:{occurrence.line_number}: {occurrence.line}")
        print(f"\n{len(occurrences)} place(s). Update each one or list it under `keep`.")
        return 0

    if argv:
        print(__doc__)
        return 2

    problems = check(root)
    for problem in problems:
        print(problem)
    if problems:
        print(f"\n{len(problems)} rename problem(s). See {REGISTRY}.")
        return 1
    print(f"Rename check passed ({len(load_renames(root))} rename(s) on record).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
