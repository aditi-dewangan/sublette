"""Sublette's own reading of a plain-words request: no language model, no
cost, always available. The assistant uses it when no model is set up, and
falls back to it when the model is down, slow or answers garbage.

It turns "furnished room for the summer under $1,200" into the renter
profile's fields. It knows dates (month names, ranges, seasons), budgets,
search radius, the type of space, and every preference, with "must" or
"nice" depending on words such as "ideally" or "would be nice".
"""

import calendar
import re
from datetime import date

from app.schemas.assistant import PreferenceChanges
from app.schemas.renter_profile import MAX_RADIUS_M, MIN_RADIUS_M, Preference

METERS_PER_MILE = 1_609.344
WALKING_DISTANCE_M = 1_600

MONTHS = {
    name: number
    for number in range(1, 13)
    for name in (calendar.month_name[number].lower(), calendar.month_abbr[number].lower())
}
MONTH = (
    r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?"
    r"|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
)
# "to", a hyphen, an en dash (typed by phones), "through" and so on.
BETWEEN = r"(?:to|-|\u2013|through|thru|until|till)"
RANGE = re.compile(
    rf"\b{MONTH}\.?\s*(\d{{1,2}})?(?:st|nd|rd|th)?\s*{BETWEEN}\s*"
    rf"{MONTH}\.?\s*(\d{{1,2}})?(?:st|nd|rd|th)?\b",
    re.IGNORECASE,
)
SINGLE_MONTH = re.compile(rf"\b(?:in|for|during)\s+{MONTH}\b", re.IGNORECASE)
# (start month, day), (end month, day)
SEASONS = {
    "summer": ((6, 1), (8, 31)),
    "fall": ((9, 1), (12, 15)),
    "autumn": ((9, 1), (12, 15)),
    "spring": ((1, 15), (5, 15)),
}

NUMBER_WORDS = {"no": 0, "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5}
NICE_WORDS = re.compile(
    r"\b(nice|ideally|ideal|prefer|preferably|preferred|bonus|would love|if possible|plus)\b",
    re.IGNORECASE,
)

# field -> pattern that asks for it
FEATURES = {
    "private_bathroom": re.compile(r"\b(own|private)\s+bath(room)?\b", re.I),
    "furnished": re.compile(r"\bfurnished\b", re.I),
    "laundry": re.compile(r"\b(laundry|washer|dryer|w/d)\b", re.I),
    "parking": re.compile(r"\b(parking|garage|place to park|park my car)\b", re.I),
    "pet_free": re.compile(
        r"\b(no pets?|pet[- ]free|allergic to (cats|dogs|pets|animals))\b", re.I
    ),
    "smoke_free": re.compile(
        r"(\bnon[- ]?smok\w*|\bno smok\w*|\bsmoke[- ]free\b|\bno smokers\b)", re.I
    ),
}
WOMEN = re.compile(r"\b(female|females|women|woman|girls?|all[- ]girls)\b", re.I)
MEN = re.compile(r"\b(male|males|men|guys|boys?)\b", re.I)
HOUSEMATE_CONTEXT = re.compile(
    r"\b(roommates?|housemates?|living with|live with|in the house|only)\b", re.I
)
ALONE = re.compile(r"\b(no (room|house)mates|live alone|living alone|by myself|on my own)\b", re.I)
MOST_MATES = re.compile(
    r"\b(?:at most|max(?:imum)?|up to|no more than)\s+(\d+|one|two|three|four|five)\s+"
    r"(?:room|house)mates?\b"
    r"|\b(\d+|one|two|three|four|five)\s+(?:room|house)mates?\s+max\b",
    re.I,
)

ENTIRE = re.compile(
    r"\b(studio|whole (apartment|place|unit|house)|entire (apartment|place|unit|house)|"
    r"own (apartment|place)|1\s?br)\b",
    re.I,
)
SHARED = re.compile(r"\bshared room\b", re.I)
PRIVATE = re.compile(r"\b(private room|own room|room)\b", re.I)

BUDGET = re.compile(
    r"(?:(?P<word>under|below|max(?:imum)?|budget(?: is| of)?|up to|less than|<)\s*\$?\s?"
    r"(?P<a>\d[\d,]*(?:\.\d+)?)\s?(?P<ak>k)?\b)"
    r"|(?:\$\s?(?P<b>\d[\d,]*(?:\.\d+)?)\s?(?P<bk>k)?\b)"
    r"|(?:\b(?P<c>\d[\d,]*)\s?(?P<ck>k)?\s?(?:/\s?mo(?:nth)?|a month|per month)\b)",
    re.IGNORECASE,
)
RADIUS = re.compile(r"\bwithin\s+(\d+(?:\.\d+)?)\s*(miles?|mi|km|kilometers?)\b", re.I)
WALKING = re.compile(r"\bwalking distance\b|\bwalkable\b", re.I)


def _clauses(text: str) -> list[str]:
    return [part for part in re.split(r"[,;.!?]|\bbut\b", text) if part.strip()]


def _importance(clause: str) -> str:
    return "nice" if NICE_WORDS.search(clause) else "must"


def _number(word: str) -> int:
    return NUMBER_WORDS[word.lower()] if word.lower() in NUMBER_WORDS else int(word)


def _next(today: date, month: int, day: int) -> date:
    """The first `month`/`day` that hasn't passed yet."""
    year = today.year
    day = min(day, calendar.monthrange(year, month)[1])
    if (month, day) < (today.month, today.day):
        year += 1
    return date(year, month, min(day, calendar.monthrange(year, month)[1]))


def _after(start: date, month: int, day: int | None) -> date:
    year = start.year if month >= start.month else start.year + 1
    last = calendar.monthrange(year, month)[1]
    return date(year, month, min(day or last, last))


def dates(text: str, today: date) -> tuple[date | None, date | None]:
    found = RANGE.search(text)
    if found:
        first, first_day, second, second_day = found.groups()
        start = _next(today, MONTHS[first[:3].lower()], int(first_day or 1))
        return start, _after(
            start, MONTHS[second[:3].lower()], int(second_day) if second_day else None
        )
    lowered = text.lower()
    for season, ((start_month, start_day), (end_month, end_day)) in SEASONS.items():
        if re.search(rf"\b{season}\b", lowered):
            start = _next(today, start_month, start_day)
            end = _after(start, end_month, end_day)
            if end < today:
                start, end = start.replace(year=start.year + 1), end.replace(year=end.year + 1)
            return start, end
    single = SINGLE_MONTH.search(text)
    if single:
        month = MONTHS[single.group(1)[:3].lower()]
        start = _next(today, month, 1)
        return start, _after(start, month, None)
    return None, None


def budget(text: str) -> int | None:
    for match in BUDGET.finditer(text):
        raw = match.group("a") or match.group("b") or match.group("c")
        thousands = match.group("ak") or match.group("bk") or match.group("ck")
        value = float(raw.replace(",", ""))
        if thousands:
            value *= 1000
        if 100 <= value <= 100_000:
            return round(value * 100)
    return None


def radius(text: str) -> int | None:
    found = RADIUS.search(text)
    if found:
        amount, unit = float(found.group(1)), found.group(2).lower()
        meters = amount * (1000 if unit.startswith("k") else METERS_PER_MILE)
        return max(MIN_RADIUS_M, min(MAX_RADIUS_M, round(meters)))
    if WALKING.search(text):
        return WALKING_DISTANCE_M
    return None


def preferences(text: str) -> list[Preference]:
    found: dict[str, Preference] = {}

    def add(field: str, value, importance: str) -> None:
        found.setdefault(field, Preference(field=field, value=value, importance=importance))

    if ENTIRE.search(text):
        add("space_type", ["entire_unit"], "must")
    elif SHARED.search(text):
        add("space_type", ["shared_room", "private_room"], "must")
    elif PRIVATE.search(text):
        add("space_type", ["private_room"], "must")

    for clause in _clauses(text):
        importance = _importance(clause)
        for field, pattern in FEATURES.items():
            if pattern.search(clause):
                add(field, True, importance)
        if ALONE.search(clause):
            add("housemate_count", 0, importance)
        most = MOST_MATES.search(clause)
        if most:
            add("housemate_count", _number(most.group(1) or most.group(2)), importance)
        if HOUSEMATE_CONTEXT.search(clause) or re.search(r"\bonly\b", clause, re.I):
            if WOMEN.search(clause):
                add("housemate_gender", "women", importance)
            elif MEN.search(clause):
                add("housemate_gender", "men", importance)
    return list(found.values())


def understand(text: str, today: date) -> PreferenceChanges:
    start, end = dates(text, today)
    return PreferenceChanges(
        start_date=start,
        end_date=end,
        max_rent_cents=budget(text),
        radius_m=radius(text),
        preferences=preferences(text),
    )
