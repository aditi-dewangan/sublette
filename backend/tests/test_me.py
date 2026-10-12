"""GET, PATCH and DELETE /v1/me: the signed-in user's own profile."""

from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import EmailCode, User
from tests.conftest import Clock, RecordingMailer, bearer, sign_in

COMPLETE_PROFILE = {
    "first_name": "Aditi",
    "year": "junior",
    "program": "Informatics",
    "bio": "Winter internship in Austin. Tidy, quiet, plant person.",
    "smokes": False,
    "has_pets": False,
}


def test_a_new_account_has_an_empty_incomplete_profile(client: TestClient, aditi: dict) -> None:
    body = client.get("/v1/me", headers=bearer(aditi)).json()

    assert body["email"] == "aditi@uw.edu"
    assert body["verified"] is True
    assert body["school"]["name"] == "University of Washington"
    assert body["profile_complete"] is False
    for field in ("first_name", "year", "program", "bio", "photo_url", "gender"):
        assert body[field] is None
    assert body["smokes"] is None and body["has_pets"] is None


def test_filling_in_the_profile_completes_it(client: TestClient, aditi: dict) -> None:
    response = client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)

    assert response.status_code == 200
    body = response.json()
    assert body["profile_complete"] is True
    assert {key: body[key] for key in COMPLETE_PROFILE} == COMPLETE_PROFILE
    # Gender is optional and stays unanswered.
    assert body["gender"] is None
    assert client.get("/v1/me", headers=bearer(aditi)).json() == body


def test_each_required_answer_is_needed_for_a_complete_profile(
    client: TestClient, aditi: dict
) -> None:
    sent: dict = {}
    for field in ("first_name", "year", "program", "smokes"):
        sent[field] = COMPLETE_PROFILE[field]
        body = client.patch("/v1/me", headers=bearer(aditi), json=sent).json()
        assert body["profile_complete"] is False, field

    body = client.patch("/v1/me", headers=bearer(aditi), json={"has_pets": True}).json()

    assert body["profile_complete"] is True
    assert body["has_pets"] is True


def test_a_patch_changes_only_the_fields_it_names(client: TestClient, aditi: dict) -> None:
    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)

    body = client.patch("/v1/me", headers=bearer(aditi), json={"program": "Design"}).json()

    assert body["program"] == "Design"
    assert body["first_name"] == "Aditi"
    assert body["bio"] == COMPLETE_PROFILE["bio"]


def test_optional_answers_can_be_set_and_cleared(client: TestClient, aditi: dict) -> None:
    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)

    set_body = client.patch("/v1/me", headers=bearer(aditi), json={"gender": "woman"}).json()
    cleared = client.patch("/v1/me", headers=bearer(aditi), json={"gender": None, "bio": ""}).json()

    assert set_body["gender"] == "woman"
    assert cleared["gender"] is None
    assert cleared["bio"] is None
    assert cleared["profile_complete"] is True


def test_names_are_trimmed(client: TestClient, aditi: dict) -> None:
    body = client.patch("/v1/me", headers=bearer(aditi), json={"first_name": "  Aditi  "}).json()

    assert body["first_name"] == "Aditi"


def test_each_invalid_field_is_named_in_the_error(client: TestClient, aditi: dict) -> None:
    response = client.patch(
        "/v1/me",
        headers=bearer(aditi),
        json={
            "first_name": "   ",
            "year": "sixth",
            "program": "x" * 101,
            "bio": "y" * 161,
            "gender": "other",
            "smokes": "sometimes",
        },
    )

    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "validation_error"
    assert {item["field"] for item in body["fields"]} == {
        "first_name",
        "year",
        "program",
        "bio",
        "gender",
        "smokes",
    }


def test_a_required_answer_cannot_be_emptied(client: TestClient, aditi: dict) -> None:
    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)

    response = client.patch("/v1/me", headers=bearer(aditi), json={"first_name": None})

    assert response.status_code == 422
    assert response.json()["fields"] == [{"field": "first_name", "message": "This can't be empty."}]
    assert client.get("/v1/me", headers=bearer(aditi)).json()["first_name"] == "Aditi"


def test_fields_the_user_does_not_own_cannot_be_changed(
    client: TestClient, aditi: dict, db: Session
) -> None:
    for forbidden in (
        {"email": "someone@harvard.edu"},
        {"status": "active"},
        {"verified": False},
        {"school_id": "00000000-0000-0000-0000-000000000000"},
        {"id": "00000000-0000-0000-0000-000000000000"},
    ):
        response = client.patch("/v1/me", headers=bearer(aditi), json=forbidden)
        assert response.status_code == 422, forbidden

    assert db.scalars(select(User)).one().email == "aditi@uw.edu"


def test_one_account_cannot_read_or_change_another(
    client: TestClient, mailer: RecordingMailer, aditi: dict
) -> None:
    sam = sign_in(client, mailer, "sam@northeastern.edu")
    client.patch("/v1/me", headers=bearer(sam), json={"first_name": "Sam"})

    mine = client.get("/v1/me", headers=bearer(aditi)).json()

    assert mine["email"] == "aditi@uw.edu"
    assert mine["first_name"] is None


# --- Deleting the account -----------------------------------------------------


def test_deleting_the_account_removes_the_user_row(
    client: TestClient, aditi: dict, db: Session
) -> None:
    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)

    response = client.delete("/v1/me", headers=bearer(aditi))

    assert response.status_code == 204
    assert response.content == b""
    assert db.scalar(select(func.count()).select_from(User)) == 0


def test_after_deletion_every_token_stops_working(client: TestClient, aditi: dict) -> None:
    client.delete("/v1/me", headers=bearer(aditi))

    me = client.get("/v1/me", headers=bearer(aditi))
    refresh = client.post("/v1/auth/refresh", json={"refresh_token": aditi["refresh_token"]})

    assert me.status_code == 401
    assert me.json()["code"] == "token_invalid"
    assert refresh.status_code == 401


def test_deletion_also_removes_a_pending_code_and_leaves_other_accounts(
    client: TestClient, mailer: RecordingMailer, aditi: dict, db: Session, clock: Clock
) -> None:
    sam = sign_in(client, mailer, "sam@northeastern.edu")
    clock.advance(seconds=31)
    client.post("/v1/auth/request-code", json={"email": "aditi@uw.edu"})
    assert db.scalar(select(func.count()).select_from(EmailCode)) == 1

    client.delete("/v1/me", headers=bearer(aditi))

    assert db.scalar(select(func.count()).select_from(EmailCode)) == 0
    assert client.get("/v1/me", headers=bearer(sam)).status_code == 200


def test_signing_up_again_after_deletion_starts_from_nothing(
    client: TestClient, mailer: RecordingMailer, aditi: dict, clock: Clock
) -> None:
    client.patch("/v1/me", headers=bearer(aditi), json=COMPLETE_PROFILE)
    client.delete("/v1/me", headers=bearer(aditi))
    clock.advance(seconds=31)

    again = sign_in(client, mailer, "aditi@uw.edu")

    assert again["user"]["id"] != aditi["user"]["id"]
    assert again["user"]["first_name"] is None
    assert again["user"]["profile_complete"] is False
