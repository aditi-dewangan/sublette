"""SQLAlchemy table models. Import each model here so Alembic can see it."""

from app.models.alert import Alert
from app.models.analytics import CrashReport, Event
from app.models.assistant import AssistantQuery
from app.models.chat import DeviceToken, Message
from app.models.email_code import EmailCode
from app.models.listing import Listing, ListingPhoto
from app.models.rate_limit import RateLimitHit
from app.models.renter_profile import RenterProfile
from app.models.safety import Block, Report, Upload
from app.models.school import School, SchoolDomain
from app.models.stored_file import StoredFile
from app.models.swipe import Match, SavedListing, Swipe
from app.models.user import User

__all__ = [
    "Alert",
    "AssistantQuery",
    "Block",
    "CrashReport",
    "DeviceToken",
    "EmailCode",
    "Event",
    "Listing",
    "ListingPhoto",
    "Match",
    "Message",
    "RateLimitHit",
    "RenterProfile",
    "Report",
    "SavedListing",
    "School",
    "SchoolDomain",
    "StoredFile",
    "Swipe",
    "Upload",
    "User",
]
