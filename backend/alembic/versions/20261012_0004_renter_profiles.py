"""Renter profiles, and who lives in a listing's home.

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-12
"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    op.create_table(
        "renter_profiles",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("start_date", sa.Date(), nullable=True),
        sa.Column("end_date", sa.Date(), nullable=True),
        sa.Column("flexibility_days", sa.Integer(), server_default="0", nullable=False),
        sa.Column("max_rent_cents", sa.Integer(), nullable=True),
        sa.Column(
            "preferences",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="[]",
            nullable=False,
        ),
        sa.Column("pin_latitude", sa.Float(), nullable=True),
        sa.Column("pin_longitude", sa.Float(), nullable=True),
        sa.Column("radius_m", sa.Integer(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_renter_profiles_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_renter_profiles")),
    )
    op.add_column("listings", sa.Column("household_gender", sa.String(length=10), nullable=True))


def downgrade() -> None:
    op.drop_column("listings", "household_gender")
    op.drop_table("renter_profiles")
