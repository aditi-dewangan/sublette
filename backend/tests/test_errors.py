"""Every error leaves the server as {code, message}."""

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from pydantic import BaseModel, Field


def test_unknown_path_uses_the_error_shape(client: TestClient) -> None:
    response = client.get("/v1/nope")

    assert response.status_code == 404
    assert response.json() == {"code": "not_found", "message": "Not Found"}


def test_wrong_method_uses_the_error_shape(client: TestClient) -> None:
    response = client.post("/health")

    assert response.status_code == 405
    assert response.json()["code"] == "method_not_allowed"


def test_http_exception_keeps_its_message(app: FastAPI) -> None:
    @app.get("/boom-403")
    def forbidden() -> None:
        raise HTTPException(status_code=403, detail="Only the owner can see this.")

    with TestClient(app) as client:
        response = client.get("/boom-403")

    assert response.status_code == 403
    assert response.json() == {"code": "forbidden", "message": "Only the owner can see this."}


def test_validation_error_names_each_field(app: FastAPI) -> None:
    class Body(BaseModel):
        rent_cents: int = Field(gt=0)
        first_name: str

    @app.post("/echo")
    def echo(body: Body) -> Body:
        return body

    with TestClient(app) as client:
        response = client.post("/echo", json={"rent_cents": 0})

    assert response.status_code == 422
    body = response.json()
    assert body["code"] == "validation_error"
    assert body["message"]
    assert {item["field"] for item in body["fields"]} == {"rent_cents", "first_name"}
    assert all(item["message"] for item in body["fields"])


def test_unexpected_error_is_hidden_behind_a_generic_message(app: FastAPI) -> None:
    @app.get("/boom-500")
    def broken() -> None:
        raise RuntimeError("secret internal detail")

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/boom-500")

    assert response.status_code == 500
    assert response.json() == {
        "code": "internal_error",
        "message": "Something went wrong on our side.",
    }
    assert "secret" not in response.text
