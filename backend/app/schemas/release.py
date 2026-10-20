from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, StringConstraints

from app.services.analytics import FEATURES

Feature = Literal[FEATURES]  # type: ignore[valid-type]


class EventIn(BaseModel):
    """`app_opened` once each time the app comes to the front; `feature_used`
    with the feature's name."""

    model_config = ConfigDict(extra="forbid")

    name: Literal["app_opened", "feature_used"]
    feature: Feature | None = None


class CrashIn(BaseModel):
    """One diagnostic report from Apple's MetricKit, as JSON text."""

    model_config = ConfigDict(extra="forbid")

    kind: Literal["crash", "hang", "cpu", "disk"]
    app_version: Annotated[str, StringConstraints(min_length=1, max_length=20)]
    os_version: Annotated[str, StringConstraints(min_length=1, max_length=40)]
    payload: Annotated[str, StringConstraints(min_length=1, max_length=65_536)]


class ReferralIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: Annotated[str, StringConstraints(strip_whitespace=True, min_length=4, max_length=12)]
