"""SQLAlchemy table models. Import each model here so Alembic can see it."""

from app.models.email_code import EmailCode
from app.models.rate_limit import RateLimitHit
from app.models.school import School, SchoolDomain
from app.models.user import User

__all__ = ["EmailCode", "RateLimitHit", "School", "SchoolDomain", "User"]
