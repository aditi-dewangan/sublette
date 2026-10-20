"""Which email addresses may sign up."""

import pytest

from app.errors import ApiError
from app.services.emails import (
    domain_and_parents,
    is_blocked,
    normalize_email,
    registrable_domain,
    require_school_email,
)

NOTHING_BLOCKED: frozenset[str] = frozenset()


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("aditi@uw.edu", "aditi@uw.edu"),
        ("  Aditi@UW.edu ", "aditi@uw.edu"),
        ("first.last+sublette@cs.washington.edu", "first.last@cs.washington.edu"),
        ("o'brien@northeastern.edu", "o'brien@northeastern.edu"),
        ("student@u.northwestern.edu", "student@u.northwestern.edu"),
    ],
)
def test_school_addresses_are_accepted_and_normalized(raw: str, expected: str) -> None:
    assert require_school_email(raw, NOTHING_BLOCKED) == expected


@pytest.mark.parametrize(
    "raw",
    [
        "aditi@gmail.com",
        "aditi@uw.edu.evil.com",
        "aditi@student.unimelb.edu.au",
        "aditi@ox.ac.uk",
        "aditi@notedu",
        "aditi@fakeedu.com",
    ],
)
def test_addresses_that_do_not_end_in_edu_are_refused(raw: str) -> None:
    with pytest.raises(ApiError) as error:
        require_school_email(raw, NOTHING_BLOCKED)

    assert error.value.code in {"not_edu_email", "invalid_email"}
    assert error.value.status_code == 422


@pytest.mark.parametrize(
    "raw",
    ["", "aditi", "@uw.edu", "aditi@", "aditi@@uw.edu", "a b@uw.edu", "a..b@uw.edu", "a@.edu"],
)
def test_things_that_are_not_addresses_are_refused(raw: str) -> None:
    with pytest.raises(ApiError) as error:
        normalize_email(raw)

    assert error.value.code == "invalid_email"
    assert error.value.fields[0].field == "email"


def test_overlong_addresses_are_refused() -> None:
    with pytest.raises(ApiError):
        normalize_email("a" * 250 + "@uw.edu")


def test_a_blocked_domain_also_blocks_its_subdomains() -> None:
    blocked = frozenset({"alumni.example.edu"})

    assert is_blocked("alumni.example.edu", blocked)
    assert is_blocked("mail.alumni.example.edu", blocked)
    assert not is_blocked("example.edu", blocked)
    assert not is_blocked("notalumni.example.edu", blocked)


def test_blocked_domain_is_refused_with_its_own_code() -> None:
    with pytest.raises(ApiError) as error:
        require_school_email("old@alumni.example.edu", frozenset({"alumni.example.edu"}))

    assert error.value.code == "domain_blocked"
    assert error.value.status_code == 403


def test_domain_helpers() -> None:
    assert registrable_domain("cs.washington.edu") == "washington.edu"
    assert registrable_domain("uw.edu") == "uw.edu"
    assert domain_and_parents("a.b.uw.edu") == ["a.b.uw.edu", "b.uw.edu", "uw.edu"]
