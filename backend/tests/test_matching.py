"""The matching rules, one row per rule and direction. No database needed."""

import uuid
from dataclasses import replace
from datetime import date

import pytest

from app.models import Listing
from app.services.matching import (
    Renter,
    failures,
    gender_fits,
    is_eligible,
    reasons,
    score,
    score_parts,
    stay_days,
)

MY_SCHOOL = uuid.uuid4()
OTHER_SCHOOL = uuid.uuid4()
PIN = (47.6553, -122.3035)
# About 0.0449 degrees of latitude is 5 km.
DEGREES_PER_KM = 1 / 111.32


def make_renter(preferences=(), **changes) -> Renter:
    base = Renter(
        user_id=uuid.uuid4(),
        school_id=MY_SCHOOL,
        gender="woman",
        smokes=False,
        has_pets=False,
        start_date=date(2027, 6, 1),
        end_date=date(2027, 8, 30),  # 90 days
        flexibility_days=0,
        max_rent_cents=120_000,
        preferences=tuple(preferences),
        pin_latitude=PIN[0],
        pin_longitude=PIN[1],
        radius_m=5_000,
    )
    return replace(base, **changes)


def make_listing(**changes) -> Listing:
    """A listing that every rule accepts, at the renter's pin, under budget."""
    values = dict(
        id=uuid.uuid4(),
        status="active",
        space_type="private_room",
        bathroom="private",
        furnished=True,
        laundry=True,
        parking=True,
        housemates_staying=2,
        household_gender="women",
        pets_allowed=True,
        smoking_allowed=True,
        gender_preference="any",
        same_school_only=False,
        min_stay_days=0,
        start_date=date(2027, 6, 1),
        end_date=date(2027, 8, 30),
        rent_cents=100_000,
        public_latitude=PIN[0],
        public_longitude=PIN[1],
    )
    values.update(changes)
    return Listing(**values)


def must(field, value=True):
    return (field, value, "must")


def nice(field, value=True):
    return (field, value, "nice")


def found(renter: Renter, listing: Listing, school=MY_SCHOOL) -> list[str]:
    return [failure.field for failure in failures(renter, listing, school)]


# --- Lister filters, both directions -------------------------------------------

LISTER_FILTERS = [
    # (case, renter changes, listing changes, lister's school, expected failures)
    ("renter with pets, no pets", {"has_pets": True}, {"pets_allowed": False}, MY_SCHOOL, ["pets"]),
    ("renter with pets, pets welcome", {"has_pets": True}, {"pets_allowed": True}, MY_SCHOOL, []),
    ("renter without pets, no pets", {"has_pets": False}, {"pets_allowed": False}, MY_SCHOOL, []),
    ("smoker, no smoking", {"smokes": True}, {"smoking_allowed": False}, MY_SCHOOL, ["smoking"]),
    ("smoker, smokers welcome", {"smokes": True}, {"smoking_allowed": True}, MY_SCHOOL, []),
    ("non-smoker, no smoking", {"smokes": False}, {"smoking_allowed": False}, MY_SCHOOL, []),
    ("woman, for women", {"gender": "woman"}, {"gender_preference": "women"}, MY_SCHOOL, []),
    ("man, for women", {"gender": "man"}, {"gender_preference": "women"}, MY_SCHOOL, ["gender"]),
    (
        "non-binary, for women",
        {"gender": "nonbinary"},
        {"gender_preference": "women"},
        MY_SCHOOL,
        [],
    ),
    (
        "unstated, for women",
        {"gender": None},
        {"gender_preference": "women"},
        MY_SCHOOL,
        ["gender_missing"],
    ),
    ("man, for men", {"gender": "man"}, {"gender_preference": "men"}, MY_SCHOOL, []),
    ("woman, for men", {"gender": "woman"}, {"gender_preference": "men"}, MY_SCHOOL, ["gender"]),
    ("non-binary, for men", {"gender": "nonbinary"}, {"gender_preference": "men"}, MY_SCHOOL, []),
    (
        "unstated, for men",
        {"gender": None},
        {"gender_preference": "men"},
        MY_SCHOOL,
        ["gender_missing"],
    ),
    ("unstated, no preference", {"gender": None}, {"gender_preference": "any"}, MY_SCHOOL, []),
    ("other school, school only", {}, {"same_school_only": True}, OTHER_SCHOOL, ["school"]),
    ("same school, school only", {}, {"same_school_only": True}, MY_SCHOOL, []),
    ("other school, any school", {}, {"same_school_only": False}, OTHER_SCHOOL, []),
    (
        "no overlap at all",
        {},
        {"start_date": date(2027, 9, 10), "end_date": date(2027, 12, 1)},
        MY_SCHOOL,
        ["dates"],
    ),
    (
        "no overlap, but flexible enough",
        {"flexibility_days": 14},
        {"start_date": date(2027, 9, 10), "end_date": date(2027, 12, 1)},
        MY_SCHOOL,
        [],
    ),
    ("stay shorter than the minimum", {}, {"min_stay_days": 120}, MY_SCHOOL, ["min_stay"]),
    ("stay as long as the minimum", {}, {"min_stay_days": 90}, MY_SCHOOL, []),
]


@pytest.mark.parametrize(
    ("renter_changes", "listing_changes", "school", "expected"),
    [case[1:] for case in LISTER_FILTERS],
    ids=[case[0] for case in LISTER_FILTERS],
)
def test_lister_filters(renter_changes, listing_changes, school, expected) -> None:
    renter = make_renter(**renter_changes)
    listing = make_listing(**listing_changes)

    assert found(renter, listing, school) == expected
    assert is_eligible(renter, listing, school) is (expected == [])


# --- Renter must-haves, both directions ----------------------------------------

MUST_HAVES = [
    ("space type wanted", must("space_type", ("private_room",)), {}, True),
    ("space type not wanted", must("space_type", ("entire_unit",)), {}, False),
    ("private bathroom, has one", must("private_bathroom"), {"bathroom": "private"}, True),
    ("private bathroom, shared", must("private_bathroom"), {"bathroom": "shared"}, False),
    ("furnished, is", must("furnished"), {"furnished": True}, True),
    ("furnished, isn't", must("furnished"), {"furnished": False}, False),
    ("laundry, has", must("laundry"), {"laundry": True}, True),
    ("laundry, hasn't", must("laundry"), {"laundry": False}, False),
    ("parking, has", must("parking"), {"parking": True}, True),
    ("parking, hasn't", must("parking"), {"parking": False}, False),
    ("pet-free, no pets", must("pet_free"), {"pets_allowed": False}, True),
    ("pet-free, pets welcome", must("pet_free"), {"pets_allowed": True}, False),
    ("smoke-free, no smoking", must("smoke_free"), {"smoking_allowed": False}, True),
    ("smoke-free, smokers welcome", must("smoke_free"), {"smoking_allowed": True}, False),
    ("at most 2 housemates, 2", must("housemate_count", 2), {"housemates_staying": 2}, True),
    ("at most 1 housemate, 2", must("housemate_count", 1), {"housemates_staying": 2}, False),
    (
        "no housemates, whole place",
        must("housemate_count", 0),
        {"space_type": "entire_unit", "housemates_staying": None},
        True,
    ),
    (
        "live with women, women",
        must("housemate_gender", "women"),
        {"household_gender": "women"},
        True,
    ),
    ("live with women, men", must("housemate_gender", "women"), {"household_gender": "men"}, False),
    (
        "live with women, mixed",
        must("housemate_gender", "women"),
        {"household_gender": "mixed"},
        False,
    ),
    ("live with men, men", must("housemate_gender", "men"), {"household_gender": "men"}, True),
    (
        "live with men, nobody staying",
        must("housemate_gender", "men"),
        {"housemates_staying": 0, "household_gender": None},
        True,
    ),
    (
        "live with men, whole place",
        must("housemate_gender", "men"),
        {"space_type": "entire_unit", "household_gender": None},
        True,
    ),
]


@pytest.mark.parametrize(
    ("preference", "listing_changes", "passes"),
    [case[1:] for case in MUST_HAVES],
    ids=[case[0] for case in MUST_HAVES],
)
def test_must_haves(preference, listing_changes, passes) -> None:
    listing = make_listing(**listing_changes)

    assert found(make_renter([preference]), listing) == ([] if passes else [preference[0]])


@pytest.mark.parametrize("importance", ["nice", "off"])
@pytest.mark.parametrize(
    ("preference", "listing_changes"),
    [(case[1], case[2]) for case in MUST_HAVES if not case[3]],
)
def test_nice_and_off_never_hide_a_listing(importance, preference, listing_changes) -> None:
    field, value, _ = preference
    listing = make_listing(**listing_changes)

    assert found(make_renter([(field, value, importance)]), listing) == []


def test_every_failure_is_listed_not_just_the_first() -> None:
    renter = make_renter([must("furnished"), must("parking")], has_pets=True, gender=None)
    listing = make_listing(
        furnished=False, parking=False, pets_allowed=False, gender_preference="women"
    )

    assert found(renter, listing) == ["pets", "gender_missing", "furnished", "parking"]


@pytest.mark.parametrize(
    ("gender", "preference", "fits"),
    [
        ("woman", "women", True),
        ("woman", "men", False),
        ("man", "men", True),
        ("man", "women", False),
        ("nonbinary", "women", True),
        ("nonbinary", "men", True),
        (None, "women", False),
        (None, "men", False),
        (None, "any", True),
        ("man", "any", True),
    ],
)
def test_gender_rule(gender, preference, fits) -> None:
    assert gender_fits(gender, preference) is fits


# --- Dates -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("listing_dates", "flex", "expected"),
    [
        ((date(2027, 6, 1), date(2027, 8, 30)), 0, 90),
        ((date(2027, 5, 1), date(2027, 12, 1)), 0, 90),  # longer than wanted: capped
        ((date(2027, 7, 16), date(2027, 12, 1)), 0, 45),  # covers the second half
        ((date(2027, 9, 1), date(2027, 12, 1)), 0, 0),
        ((date(2027, 9, 1), date(2027, 12, 1)), 7, 5),  # a week later: Aug 30 + 7 = Sep 6
    ],
)
def test_stay_days(listing_dates, flex, expected) -> None:
    start, end = listing_dates
    renter = make_renter(flexibility_days=flex)

    assert stay_days(renter, make_listing(start_date=start, end_date=end)) == expected


# --- Score -------------------------------------------------------------------------


def test_a_perfect_fit_scores_100() -> None:
    assert score(make_renter(), make_listing()) == 100


@pytest.mark.parametrize(
    ("listing_changes", "expected"),
    [
        ({}, 35),
        ({"start_date": date(2027, 7, 16), "end_date": date(2027, 12, 1)}, 17.5),
        ({"start_date": date(2027, 9, 1), "end_date": date(2027, 12, 1)}, 0),
    ],
)
def test_dates_are_worth_35(listing_changes, expected) -> None:
    parts = score_parts(make_renter(), make_listing(**listing_changes))

    assert parts["dates"] == pytest.approx(expected)


@pytest.mark.parametrize(
    ("rent", "expected"),
    [(60_000, 25), (120_000, 25), (135_000, 12.5), (150_000, 0), (300_000, 0)],
)
def test_rent_against_budget_is_worth_25(rent, expected) -> None:
    parts = score_parts(make_renter(max_rent_cents=120_000), make_listing(rent_cents=rent))

    assert parts["rent"] == pytest.approx(expected)


@pytest.mark.parametrize(("km", "expected"), [(0, 20), (2.5, 10), (5, 0), (7, 0)])
def test_distance_from_the_pin_is_worth_20(km, expected) -> None:
    listing = make_listing(public_latitude=PIN[0] + km * DEGREES_PER_KM)

    parts = score_parts(make_renter(radius_m=5_000), listing)

    assert parts["distance"] == pytest.approx(expected, abs=0.05)


@pytest.mark.parametrize(
    ("preferences", "listing_changes", "expected"),
    [
        ([], {}, 20),
        ([nice("furnished"), nice("parking")], {}, 20),
        ([nice("furnished"), nice("parking")], {"parking": False}, 10),
        ([nice("furnished"), nice("parking")], {"parking": False, "furnished": False}, 0),
        ([must("furnished"), nice("parking")], {"parking": False}, 0),
    ],
)
def test_nice_to_haves_are_worth_20(preferences, listing_changes, expected) -> None:
    parts = score_parts(make_renter(preferences), make_listing(**listing_changes))

    assert parts["nice_to_haves"] == pytest.approx(expected)


def test_the_score_is_a_whole_number_from_0_to_100() -> None:
    worst = make_listing(
        start_date=date(2027, 9, 1),
        end_date=date(2027, 12, 1),
        rent_cents=500_000,
        public_latitude=PIN[0] + 9 * DEGREES_PER_KM,
        furnished=False,
    )

    assert score(make_renter([nice("furnished")]), worst) == 0
    assert isinstance(score(make_renter(), make_listing(rent_cents=135_000)), int)


# --- Reasons -------------------------------------------------------------------------


def test_reasons_for_a_great_fit() -> None:
    renter = make_renter([nice("furnished"), nice("laundry")], max_rent_cents=115_000)

    assert reasons(renter, make_listing(rent_cents=100_000)) == [
        "Fits your dates",
        "$150 under budget",
        "Right by your pin",
        "Furnished and in-unit laundry",
    ]


def test_reasons_for_a_partial_fit() -> None:
    renter = make_renter([nice("parking")])
    listing = make_listing(
        start_date=date(2027, 7, 16),
        end_date=date(2027, 12, 1),
        rent_cents=128_000,
        public_latitude=PIN[0] + 1.609344 * DEGREES_PER_KM,
        parking=False,
    )

    assert reasons(renter, listing) == [
        "Covers 45 of your 90 days",
        "$80 over budget",
        "1.0 mi from your pin",
    ]


def test_reasons_at_budget_and_with_many_nice_to_haves() -> None:
    renter = make_renter([nice("furnished"), nice("laundry"), nice("parking")])

    found_reasons = reasons(renter, make_listing(rent_cents=120_000))

    assert found_reasons[1] == "Right at your budget"
    assert found_reasons[3] == "Furnished, in-unit laundry and 1 more"
    assert 3 <= len(found_reasons) <= 4


# --- What the lister sees -------------------------------------------------------------

from app.services.matching import lister_fits  # noqa: E402


@pytest.mark.parametrize(
    ("listing_changes", "expected"),
    [
        ({}, ["Stays 90 days of your dates", "Verified UW student"]),
        (
            {"min_stay_days": 60, "same_school_only": True},
            ["Stays 90 days (you asked for 60+)", "UW student, like you"],
        ),
        (
            {"pets_allowed": False, "smoking_allowed": False, "gender_preference": "women"},
            [
                "Stays 90 days of your dates",
                "Verified UW student",
                "No pets",
                "Doesn't smoke",
                "Fits your preference for women",
            ],
        ),
    ],
)
def test_lister_fits(listing_changes, expected) -> None:
    assert lister_fits(make_renter(), make_listing(**listing_changes), "UW") == expected


# --- The sentence on the card ---------------------------------------------------------

from app.services.matching import summary  # noqa: E402


def test_summary_of_a_great_fit_has_no_number_in_it() -> None:
    renter = make_renter([nice("furnished"), nice("laundry")], max_rent_cents=115_000)

    text = summary(renter, make_listing(rent_cents=100_000))

    assert text == (
        "Fits your dates, $150 under budget and right by your pin. Furnished and in-unit laundry."
    )
    assert "%" not in text


def test_summary_of_a_partial_fit() -> None:
    renter = make_renter([nice("parking")])
    listing = make_listing(
        start_date=date(2027, 7, 16),
        end_date=date(2027, 12, 1),
        rent_cents=128_000,
        public_latitude=PIN[0] + 1.609344 * DEGREES_PER_KM,
        parking=False,
    )

    assert summary(renter, listing) == (
        "Covers 45 of your 90 days, $80 over budget and 1.0 mi from your pin."
    )
