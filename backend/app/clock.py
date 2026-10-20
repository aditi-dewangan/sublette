"""Which calendar day it is, for listing dates.

The server's clock is UTC, where the day turns over at 4 or 5 pm on the US
West Coast. Listing dates are local calendar days, so "today" is the date in
the westernmost US time zone (Hawaii, UTC-10): a listing stays up until its
last day is over everywhere a student might be.
"""

from datetime import date, datetime, timedelta

WESTERNMOST_OFFSET = timedelta(hours=10)


def local_today(now: datetime) -> date:
    return (now - WESTERNMOST_OFFSET).date()
