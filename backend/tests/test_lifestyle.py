"""Housemate lifestyle fit (issue #20)."""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.services import lifestyle
from app.services.matching import failures, lister_fits, reasons, score, summary
from tests.conftest import Clock, RecordingMailer, bearer, sign_in
from tests.test_deck import deck, make_searching_renter, put_listing
from tests.test_matching import MY_SCHOOL, make_listing, make_renter
from tests.test_me import COMPLETE_PROFILE
from tests.test_swipes import ok, user_of

QUIET_TIDY = (("sleep_schedule", "early"), ("tidiness", "tidy"), ("home_vibe", "quiet"))


def created(response) -> dict:
    assert response.status_code == 201, response.text
    return response.json()


def household(**answers) -> dict:
    return {
        "sleep_schedule": None,
        "tidiness": None,
        "guests": None,
        "home_daytime": None,
        "home_vibe": None,
        **answers,
    }


# --- The rules ----------------------------------------------------------------------


@pytest.mark.parametrize(
    ("question", "mine", "theirs", "expected"),
    [
        ("tidiness", "tidy", "tidy", 1.0),
        ("tidiness", "very_tidy", "tidy", 0.5),
        ("tidiness", "very_tidy", "relaxed", 0.0),
        ("sleep_schedule", "early", "late", 0.0),
        ("sleep_schedule", "early", "varies", 0.5),
        ("home_vibe", "either", "social", 0.5),
        ("home_vibe", "quiet", "social", 0.0),
        ("guests", "rarely", "sometimes", 0.5),
    ],
)
def test_how_close_two_answers_are(question, mine, theirs, expected) -> None:
    assert lifestyle.closeness(question, mine, theirs) == expected


def test_a_household_that_lives_alike_earns_points_and_a_sentence() -> None:
    renter = make_renter(lifestyle=QUIET_TIDY)
    alike = make_listing(**household(sleep_schedule="early", tidiness="tidy", home_vibe="quiet"))
    unlike = make_listing(
        **household(sleep_schedule="late", tidiness="relaxed", home_vibe="social")
    )
    unanswered = make_listing(**household())

    assert score(renter, alike) == min(100, score(renter, unanswered) + 8)
    # Only "relaxed" is near "tidy" (half a match on one of three questions).
    assert score(renter, unlike) == score(renter, unanswered) + 1
    assert "You'd fit in: early nights and a tidy home" in reasons(renter, alike)
    assert summary(renter, alike).endswith("You'd fit in: early nights and a tidy home.")


def test_lifestyle_never_hides_a_place() -> None:
    renter = make_renter(lifestyle=QUIET_TIDY)
    unlike = make_listing(
        **household(sleep_schedule="late", tidiness="relaxed", home_vibe="social")
    )

    assert failures(renter, unlike, MY_SCHOOL) == []


def test_it_counts_only_for_a_shared_home_and_two_shared_answers() -> None:
    renter = make_renter(lifestyle=QUIET_TIDY)
    answers = household(sleep_schedule="early", tidiness="tidy", home_vibe="quiet")
    alone = make_listing(space_type="entire_unit", housemates_staying=0, **answers)
    nobody = make_listing(housemates_staying=0, **answers)
    one_answer = make_listing(**household(sleep_schedule="early"))

    for listing in (alone, nobody, one_answer):
        assert lifestyle.fit(dict(renter.lifestyle), listing) == (0, [])
    assert lifestyle.fit((), make_listing(**answers)) == (0, [])


def test_listers_see_what_the_renter_shares_with_the_house() -> None:
    renter = make_renter(lifestyle=QUIET_TIDY)
    listing = make_listing(**household(sleep_schedule="early", tidiness="tidy"))

    assert "Lives like your housemates: early nights and a tidy home" in lister_fits(
        renter, listing, "UW"
    )


# --- Through the API ------------------------------------------------------------------


def test_students_answer_for_themselves_and_can_clear_answers(
    client: TestClient, mailer: RecordingMailer
) -> None:
    who = sign_in(client, mailer, "aditi@uw.edu")

    me = ok(
        client.patch(
            "/v1/me", headers=bearer(who), json={"sleep_schedule": "early", "home_vibe": "quiet"}
        )
    )
    assert (me["sleep_schedule"], me["home_vibe"], me["tidiness"]) == ("early", "quiet", None)
    cleared = ok(client.patch("/v1/me", headers=bearer(who), json={"sleep_schedule": None}))
    assert cleared["sleep_schedule"] is None
    bad = client.patch("/v1/me", headers=bearer(who), json={"tidiness": "spotless"})
    assert bad.status_code == 422


def test_listers_answer_for_the_housemates_only_when_someone_stays(
    client: TestClient, mailer: RecordingMailer
) -> None:
    lister = sign_in(client, mailer, "lister@uw.edu")
    shared = created(
        client.post(
            "/v1/listings",
            headers=bearer(lister),
            json={
                "space_type": "private_room",
                "housemates_staying": 2,
                "guests": "rarely",
            },
        )
    )
    alone = created(
        client.post(
            "/v1/listings",
            headers=bearer(lister),
            json={
                "space_type": "entire_unit",
                "housemates_staying": 0,
                "guests": "rarely",
            },
        )
    )

    assert shared["guests"] == "rarely"
    assert alone["guests"] is None


def test_the_deck_card_says_when_the_house_lives_like_you(
    client: TestClient, mailer: RecordingMailer, clock: Clock, db: Session
) -> None:
    renter = make_searching_renter(client, mailer, clock)
    client.patch(
        "/v1/me", headers=bearer(renter), json={"sleep_schedule": "early", "tidiness": "tidy"}
    )
    lister = sign_in(client, mailer, "lister@uw.edu")
    client.patch("/v1/me", headers=bearer(lister), json=COMPLETE_PROFILE)
    put_listing(db, clock, user_of(db, lister), sleep_schedule="early", tidiness="tidy")

    [card] = deck(client, renter)

    assert "You'd fit in: early nights and a tidy home." in card["summary"]
