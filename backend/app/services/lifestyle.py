"""Housemate lifestyle fit (issue #20): five optional questions a renter
answers about themselves and a lister about the housemates staying.

Pure functions, like services/matching.py. Lifestyle is only ever a
nice-to-have: it adds a few points and a sentence, and never hides a place.
It counts only for a shared home with someone staying, and only when both
sides answered at least two of the same questions.
"""

# Each question and its answers, in the order the app asks them.
QUESTIONS: dict[str, tuple[str, ...]] = {
    "sleep_schedule": ("early", "late", "varies"),
    "tidiness": ("very_tidy", "tidy", "relaxed"),
    "guests": ("rarely", "sometimes", "often"),
    "home_daytime": ("rarely", "sometimes", "often"),
    "home_vibe": ("quiet", "social", "either"),
}
# These are scales: neighbours on them are half a match.
SCALES = ("tidiness", "guests", "home_daytime")
# "It varies" and "Either" meet anyone halfway.
FLEXIBLE = {"sleep_schedule": "varies", "home_vibe": "either"}

LIFESTYLE_POINTS = 8
MIN_COMPARED = 2

PHRASES = {
    ("sleep_schedule", "early"): "early nights",
    ("sleep_schedule", "late"): "late nights",
    ("tidiness", "very_tidy"): "a very tidy home",
    ("tidiness", "tidy"): "a tidy home",
    ("tidiness", "relaxed"): "a relaxed home",
    ("guests", "rarely"): "few guests",
    ("guests", "often"): "having friends over",
    ("home_daytime", "often"): "working from home",
    ("home_daytime", "rarely"): "being out most days",
    ("home_vibe", "quiet"): "a quiet home",
    ("home_vibe", "social"): "a social home",
}


def answers(model) -> dict[str, str]:
    """The answered questions on a user or a listing."""
    return {
        question: getattr(model, question)
        for question in QUESTIONS
        if getattr(model, question, None) is not None
    }


def applies(listing) -> bool:
    """A shared home with someone staying: there are housemates to fit with."""
    return listing.space_type != "entire_unit" and bool(listing.housemates_staying)


def closeness(question: str, mine: str, theirs: str) -> float:
    if mine == theirs:
        return 1.0
    if question in SCALES:
        values = QUESTIONS[question]
        return 0.5 if abs(values.index(mine) - values.index(theirs)) == 1 else 0.0
    if FLEXIBLE.get(question) in (mine, theirs):
        return 0.5
    return 0.0


def compare(renter: dict[str, str], household: dict[str, str]) -> tuple[float, int, list[str]]:
    """How close two sets of answers are (0 to 1), how many questions both
    answered, and the phrases for what they share exactly."""
    both = [question for question in QUESTIONS if question in renter and question in household]
    if not both:
        return 0.0, 0, []
    total = sum(closeness(question, renter[question], household[question]) for question in both)
    shared = [
        PHRASES[(question, renter[question])]
        for question in both
        if renter[question] == household[question] and (question, renter[question]) in PHRASES
    ]
    return total / len(both), len(both), shared


def fit(renter: dict[str, str], listing) -> tuple[int, list[str]]:
    """The points this listing earns for lifestyle (0 to 8), and what is shared."""
    if not applies(listing):
        return 0, []
    value, compared, shared = compare(renter, answers(listing))
    if compared < MIN_COMPARED:
        return 0, []
    return round(LIFESTYLE_POINTS * value), shared


def phrase(shared: list[str]) -> str:
    """ "early nights and a quiet home"."""
    if len(shared) == 1:
        return shared[0]
    return ", ".join(shared[:-1]) + f" and {shared[-1]}"
