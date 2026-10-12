"""SQLAlchemy table models. Import each model here so Alembic can see it."""

from app.models.email_code import EmailCode
from app.models.listing import Listing, ListingPhoto
from app.models.rate_limit import RateLimitHit
from app.models.school import School, SchoolDomain
from app.models.stored_file import StoredFile
from app.models.user import User

__all__ = [
    "EmailCode",
    "Listing",
    "ListingPhoto",
    "RateLimitHit",
    "School",
    "SchoolDomain",
    "StoredFile",
    "User",
]
