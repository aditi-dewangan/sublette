"""Which listings a renter may see, how well each fits, and why.

Three pure functions, used by the deck and by nothing else:

* `is_eligible(renter, listing)`: False when the listing costs more than the
  renter's maximum rent, fails any of the renter's must-haves, or the renter
  fails any of the lister's filters.
  `failures` says which.
* `score(renter, listing)`: 0 to 100. Dates 35, rent under budget 25,
  distance from the pin 20, nice-to-haves 20.
* `reasons(renter, listing)`: three or four short sentences for the card.

No database, no clock: everything they need is passed in, so every rule can be
tested directly.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from typing import TYPE_CHECKING, Literal

from app.services.geo import distance_m

if TYPE_CHECKING:
    from app.models import Listing, RenterProfile, User

DATES_POINTS = 35
RENT_POINTS = 25
DISTANCE_POINTS = 20
NICE_POINTS = 20

# Rent at the budget earns RENT_AT_BUDGET of the rent points; this far under
# it (or more) earns them all.
RENT_AT_BUDGET = 15
RENT_FULL_AT_UNDER = 0.20

METERS_PER_MILE = 1_609.344

FailureKind = Literal["must_have", "lister_filter"]


@dataclass(frozen=True)
class Renter:
    """Everything matching needs to know about one renter."""

    user_id: object
    school_id: object
    gender: str | None
    smokes: bool | None
    has_pets: bool | None
    start_date: date
    end_date: date
    flexibility_days: int
    max_rent_cents: int
    preferences: tuple[tuple[str, object, str], ...]
    pin_latitude: float
    pin_longitude: float
    radius_m: int

    @classmethod
    def from_models(cls, user: User, profile: RenterProfile) -> Renter:
        return cls(
            user_id=user.id,
            school_id=user.school_id,
            gender=user.gender,
            smokes=user.smokes,
            has_pets=user.has_pets,
            start_date=profile.start_date,
            end_date=profile.end_date,
            flexibility_days=profile.flexibility_days,
            max_rent_cents=profile.max_rent_cents,
            preferences=tuple(
                (item["field"], _frozen(item["value"]), item["importance"])
                for item in profile.preferences
            ),
            pin_latitude=profile.pin_latitude,
            pin_longitude=profile.pin_longitude,
            radius_m=profile.radius_m,
        )

    def with_importance(self, importance: str) -> list[tuple[str, object]]:
        return [(field, value) for field, value, level in self.preferences if level == importance]

    @property
    def wanted_days(self) -> int:
        return (self.end_date - self.start_date).days


def _frozen(value: object) -> object:
    return tuple(value) if isinstance(value, list) else value


@dataclass(frozen=True)
class Failure:
    """One reason a renter can't see a listing.

    `field` is a preference name for must-haves (such as `furnished`) or
    `max_rent` for the budget, and one of pets, smoking, gender,
    gender_missing, school, dates, min_stay for the lister's filters.
    """

    kind: FailureKind
    field: str


# --- Dates -------------------------------------------------------------------


def stay_days(renter: Renter, listing: Listing) -> int:
    """How many of the renter's wanted days the listing covers.

    The renter's dates may move by `flexibility_days` either way, but the stay
    is never counted as longer than the renter wants.
    """
    if listing.start_date is None or listing.end_date is None:
        return 0
    flex = timedelta(days=renter.flexibility_days)
    window_start = renter.start_date - flex
    window_end = renter.end_date + flex
    overlap = (min(window_end, listing.end_date) - max(window_start, listing.start_date)).days
    return max(0, min(overlap, renter.wanted_days))


# --- Eligibility -------------------------------------------------------------


def _nobody_staying(listing: Listing) -> bool:
    return listing.space_type == "entire_unit" or not listing.housemates_staying


def meets(field: str, value: object, listing: Listing) -> bool:
    """True when the listing has what one preference asks for."""
    if field == "space_type":
        return listing.space_type in value
    if field == "private_bathroom":
        return listing.bathroom == "private"
    if field in ("furnished", "laundry", "parking"):
        return bool(getattr(listing, field))
    if field == "pet_free":
        return listing.pets_allowed is False
    if field == "smoke_free":
        return listing.smoking_allowed is False
    if field == "housemate_count":
        staying = 0 if listing.space_type == "entire_unit" else (listing.housemates_staying or 0)
        return staying <= value
    if field == "housemate_gender":
        # A place with nobody staying fits any wish about housemates.
        return _nobody_staying(listing) or listing.household_gender == value
    raise ValueError(f"unknown preference {field!r}")


def gender_fits(renter_gender: str | None, preference: str) -> bool:
    """A lister's gender preference against the renter's own gender.

    No preference fits everyone. A non-binary renter fits a place for women
    and a place for men (Aditi's rule, 2026-10-12). A renter who hasn't said
    fits neither.
    """
    if preference == "any":
        return True
    if renter_gender is None:
        return False
    if renter_gender == "nonbinary":
        return True
    return {"women": "woman", "men": "man"}[preference] == renter_gender


def failures(renter: Renter, listing: Listing, listing_school_id: object) -> list[Failure]:
    """Every rule the pair breaks. Empty means the renter may see the listing.

    `listing_school_id` is the lister's school, for "my school only".
    """
    found: list[Failure] = []

    def lister(field: str) -> None:
        found.append(Failure("lister_filter", field))

    if renter.has_pets and listing.pets_allowed is False:
        lister("pets")
    if renter.smokes and listing.smoking_allowed is False:
        lister("smoking")
    if listing.gender_preference != "any" and not gender_fits(
        renter.gender, listing.gender_preference
    ):
        lister("gender_missing" if renter.gender is None else "gender")
    if listing.same_school_only and listing_school_id != renter.school_id:
        lister("school")
    stay = stay_days(renter, listing)
    if stay == 0:
        lister("dates")
    elif stay < listing.min_stay_days:
        lister("min_stay")

    # The budget is always a must-have (Aditi, 2026-10-13).
    if listing.rent_cents is None or listing.rent_cents > renter.max_rent_cents:
        found.append(Failure("must_have", "max_rent"))
    for field, value in renter.with_importance("must"):
        if not meets(field, value, listing):
            found.append(Failure("must_have", field))
    return found


def is_eligible(renter: Renter, listing: Listing, listing_school_id: object) -> bool:
    return not failures(renter, listing, listing_school_id)


# --- Score -------------------------------------------------------------------


def distance_from_pin(renter: Renter, listing: Listing) -> float:
    """From the pin to the listing's public point. Never the exact address."""
    return distance_m(
        renter.pin_latitude,
        renter.pin_longitude,
        listing.public_latitude,
        listing.public_longitude,
    )


def score_parts(renter: Renter, listing: Listing) -> dict[str, float]:
    wanted = renter.wanted_days
    dates = DATES_POINTS * (stay_days(renter, listing) / wanted if wanted > 0 else 0)

    rent = listing.rent_cents or 0
    budget = renter.max_rent_cents
    if rent > budget:
        rent_points = 0.0  # never shown: over budget is ineligible
    else:
        under = (budget - rent) / (budget * RENT_FULL_AT_UNDER)
        rent_points = RENT_AT_BUDGET + (RENT_POINTS - RENT_AT_BUDGET) * min(1.0, under)

    distance = distance_from_pin(renter, listing)
    distance_points = DISTANCE_POINTS * max(0.0, 1 - distance / renter.radius_m)

    nice = renter.with_importance("nice")
    if nice:
        met = sum(1 for field, value in nice if meets(field, value, listing))
        nice_points = NICE_POINTS * met / len(nice)
    else:
        nice_points = NICE_POINTS
    return {
        "dates": dates,
        "rent": rent_points,
        "distance": distance_points,
        "nice_to_haves": nice_points,
    }


def score(renter: Renter, listing: Listing) -> int:
    """How well a listing fits, 0 to 100."""
    total = sum(score_parts(renter, listing).values())
    return max(0, min(100, round(total)))


# --- Reasons -----------------------------------------------------------------

NICE_NAMES = {
    "space_type": "your type of space",
    "private_bathroom": "private bathroom",
    "furnished": "furnished",
    "laundry": "in-unit laundry",
    "parking": "parking",
    "pet_free": "pet-free",
    "smoke_free": "smoke-free",
    "housemate_count": "few enough housemates",
    "housemate_gender": "the housemates you asked for",
}


def _nice_sentence(fields: list[str]) -> str:
    """ "Furnished and in-unit laundry", "Parking, pet-free and 1 more"."""
    names = [NICE_NAMES[field] for field in fields]
    if len(names) == 1:
        text = names[0]
    elif len(names) == 2:
        text = f"{names[0]} and {names[1]}"
    else:
        text = f"{names[0]}, {names[1]} and {len(names) - 2} more"
    return text[0].upper() + text[1:]


def _dollars(cents: int) -> str:
    return f"${round(cents / 100):,}"


def _miles(meters: float) -> str:
    miles = meters / METERS_PER_MILE
    if miles < 0.1:
        return "Right by your pin"
    return f"{miles:.1f} mi from your pin"


def reasons(renter: Renter, listing: Listing) -> list[str]:
    """Three or four short sentences, such as "Fits your dates" and "$150 under budget"."""
    found = []

    stay = stay_days(renter, listing)
    if stay >= renter.wanted_days:
        found.append("Fits your dates")
    else:
        found.append(f"Covers {stay} of your {renter.wanted_days} days")

    difference = renter.max_rent_cents - (listing.rent_cents or 0)
    if round(difference / 100) == 0:
        found.append("Right at your budget")
    elif difference > 0:
        found.append(f"{_dollars(difference)} under budget")
    else:
        found.append(f"{_dollars(-difference)} over budget")

    found.append(_miles(distance_from_pin(renter, listing)))

    met = [field for field, value in renter.with_importance("nice") if meets(field, value, listing)]
    if met:
        found.append(_nice_sentence(met))
    return found


# --- For the lister ----------------------------------------------------------


def lister_fits(renter: Renter, listing: Listing, renter_school_name: str) -> list[str]:
    """How a renter meets the lister's filters, for the lister's deck.

    Only call this for an eligible pair: it describes, it does not check.
    """
    stay = stay_days(renter, listing)
    found = []
    if listing.min_stay_days:
        found.append(f"Stays {stay} days (you asked for {listing.min_stay_days}+)")
    else:
        found.append(f"Stays {stay} days of your dates")
    if listing.same_school_only:
        found.append(f"{renter_school_name} student, like you")
    else:
        found.append(f"Verified {renter_school_name} student")
    if listing.pets_allowed is False:
        found.append("No pets")
    if listing.smoking_allowed is False:
        found.append("Doesn't smoke")
    if listing.gender_preference != "any":
        found.append(f"Fits your preference for {listing.gender_preference}")
    return found


# --- Score bands, for the map ----------------------------------------------------

STRONG_FROM = 75
PARTIAL_FROM = 50


def score_band(value: int) -> str:
    """strong (75 and up), partial (50 to 74) or other. The map colors pins by this."""
    if value >= STRONG_FROM:
        return "strong"
    if value >= PARTIAL_FROM:
        return "partial"
    return "other"


# --- One sentence instead of a number ---------------------------------------------


def _lower_first(text: str) -> str:
    return text[:1].lower() + text[1:] if text and not text.startswith("$") else text


def summary(renter: Renter, listing: Listing) -> str:
    """Why a listing fits, in one or two plain sentences, with no score in it.

    "Fits your dates, $150 under budget and 0.4 mi from your pin. Furnished and
    in-unit laundry."
    """
    parts = reasons(renter, listing)
    dates, rent, distance = parts[0], parts[1], parts[2]
    first = f"{dates}, {_lower_first(rent)} and {_lower_first(distance)}."
    if len(parts) > 3:
        return f"{first} {parts[3]}."
    return first
