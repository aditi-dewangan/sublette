"""A spatial index for the deck: live listings by their public point.

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-12
"""

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

# Must match `public_point()` in app/services/deck.py exactly, or PostgreSQL
# won't use it.
POINT = "geography(ST_SetSRID(ST_MakePoint(public_longitude, public_latitude), 4326))"


def upgrade() -> None:
    op.execute(
        f"CREATE INDEX ix_listings_active_public_point ON listings USING gist ({POINT}) "
        "WHERE status = 'active'"
    )


def downgrade() -> None:
    op.execute("DROP INDEX ix_listings_active_public_point")
