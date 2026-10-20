"""Scores the assistant's understanding against the evaluation set.

    make eval-assistant                      (Sublette's own rules)
    SUBLETTE_ASSISTANT_BACKEND=ollama make eval-assistant
    SUBLETTE_ASSISTANT_BACKEND=anthropic SUBLETTE_ANTHROPIC_API_KEY=... make eval-assistant

The build plan's bar is 27 of the 30 requests in app/data/assistant_eval.json.
"""

import json
import sys
from datetime import date
from pathlib import Path

from app.config import Settings
from app.schemas.assistant import PreferenceChanges
from app.services.assistant import understand_with_model
from app.services.language_model import LanguageModel, ModelUnavailable, make_language_model
from app.services.understand import understand

EVAL_SET = Path(__file__).parent / "data" / "assistant_eval.json"
PASS_MARK = 27


def as_comparable(changes: PreferenceChanges) -> dict:
    found = {}
    for key in ("start_date", "end_date", "max_rent_cents", "radius_m"):
        value = getattr(changes, key)
        if value is not None:
            found[key] = str(value) if key.endswith("date") else value
    preferences = {
        item.field: [
            sorted(item.value) if isinstance(item.value, list) else item.value,
            item.importance,
        ]
        for item in changes.preferences
    }
    if preferences:
        found["preferences"] = preferences
    return found


def expected_comparable(expected: dict) -> dict:
    found = dict(expected)
    if "preferences" in found:
        found["preferences"] = {
            field: [sorted(value) if isinstance(value, list) else value, importance]
            for field, (value, importance) in found["preferences"].items()
        }
    return found


def run(model: LanguageModel | None, out=sys.stdout) -> int:
    data = json.loads(EVAL_SET.read_text())
    today = date.fromisoformat(data["today"])
    right = 0
    for case in data["cases"]:
        try:
            if model is None:
                changes = understand(case["message"], today)
            else:
                changes = understand_with_model(model, case["message"], today)
            got = as_comparable(changes)
        except ModelUnavailable as error:
            got = {"error": str(error)}
        wanted = expected_comparable(case["expected"])
        if got == wanted:
            right += 1
        else:
            print(f"MISS: {case['message']}\n  got      {got}\n  expected {wanted}", file=out)
    total = len(data["cases"])
    print(f"{right} of {total} right (the bar is {PASS_MARK})", file=out)
    return right


def main() -> None:
    settings = Settings()
    right = run(make_language_model(settings))
    sys.exit(0 if right >= PASS_MARK else 1)


if __name__ == "__main__":
    main()
