from datetime import UTC, datetime
from typing import Annotated

from pydantic import PlainSerializer


def _utc_seconds(value: datetime) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


# Every time the API returns looks like 2027-01-04T17:00:00Z: UTC, whole
# seconds, ending in Z. The iPhone app's date decoder expects exactly this.
UtcDateTime = Annotated[datetime, PlainSerializer(_utc_seconds, return_type=str)]
