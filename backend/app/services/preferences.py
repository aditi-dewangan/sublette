"""The renter preferences: which ones exist and what value each one takes.

A renter's preferences are a list of {field, value, importance}:
  * importance "must": a listing that fails it is never shown (phase 4);
  * importance "nice": a listing that meets it scores higher;
  * importance "off": ignored, but kept so the app shows it as the renter left it.

A preference that is not in the list is the same as "off".
"""

from collections.abc import Callable
from typing import Any

from app.schemas.errors import FieldError

IMPORTANCES = ("must", "nice", "off")
SPACE_TYPES = ("entire_unit", "private_room", "shared_room")
HOUSEMATE_GENDERS = ("women", "men")
MAX_HOUSEMATES = 10


def _true_only(value: Any) -> str | None:
    # Booleans are "I want this". "I don't care" is importance off, not false.
    return None if value is True else "Send true; set importance to off to ignore it."


def _space_types(value: Any) -> str | None:
    if (
        isinstance(value, list)
        and value
        and all(isinstance(item, str) and item in SPACE_TYPES for item in value)
        and len(set(value)) == len(value)
    ):
        return None
    return "Choose one or more of entire_unit, private_room and shared_room."


def _housemate_count(value: Any) -> str | None:
    if type(value) is int and 0 <= value <= MAX_HOUSEMATES:
        return None
    return f"Send the most housemates you'd live with, from 0 to {MAX_HOUSEMATES}."


def _housemate_gender(value: Any) -> str | None:
    if value in HOUSEMATE_GENDERS:
        return None
    return "Choose women or men. For no preference, set importance to off."


# Each field and the check for its value. The order is the order the app lists them.
FIELDS: dict[str, Callable[[Any], str | None]] = {
    "space_type": _space_types,
    "private_bathroom": _true_only,
    "furnished": _true_only,
    "laundry": _true_only,
    "parking": _true_only,
    "pet_free": _true_only,
    "smoke_free": _true_only,
    "housemate_count": _housemate_count,
    "housemate_gender": _housemate_gender,
}


def preference_problems(preferences: list[dict]) -> list[FieldError]:
    """Everything wrong with a list of preferences, one message per problem."""
    problems: list[FieldError] = []
    seen: set[str] = set()
    for index, item in enumerate(preferences):
        where = f"preferences.{index}"
        field = item.get("field")
        if field not in FIELDS:
            problems.append(FieldError(field=f"{where}.field", message="Unknown preference."))
            continue
        if field in seen:
            problems.append(
                FieldError(field=f"{where}.field", message="This preference is listed twice.")
            )
            continue
        seen.add(field)
        if item.get("importance") not in IMPORTANCES:
            problems.append(
                FieldError(field=f"{where}.importance", message="Choose must, nice or off.")
            )
        message = FIELDS[field](item.get("value"))
        if message:
            problems.append(FieldError(field=f"{where}.value", message=message))
    return problems
