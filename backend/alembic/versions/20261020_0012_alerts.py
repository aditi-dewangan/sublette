"""Alerts: price drops, listings about to expire, new places, and a daily
digest; how often each student wants them; the lister's weekly summary.

Revision ID: 0012
Revises: 0011
Create Date: 2026-10-20
"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    op.create_table(
        "alerts",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(length=20), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=False),
        sa.Column("detail", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("sent_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_alerts_user_id_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["listing_id"],
            ["listings.id"],
            name=op.f("fk_alerts_listing_id_listings"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_alerts")),
    )
    op.create_index("ix_alerts_user_id_sent_at", "alerts", ["user_id", "sent_at"])
    op.create_index(op.f("ix_alerts_listing_id"), "alerts", ["listing_id"])
    op.add_column(
        "users",
        sa.Column("alert_frequency", sa.String(length=10), server_default="daily", nullable=False),
    )
    op.add_column(
        "users", sa.Column("last_lister_summary_at", sa.DateTime(timezone=True), nullable=True)
    )
    # The digest clock moves from the renter profile to the account, since
    # alerts about saved listings don't need a search.
    op.add_column("users", sa.Column("last_digest_at", sa.DateTime(timezone=True), nullable=True))
    op.execute(
        sa.text(
            "UPDATE users SET last_digest_at = renter_profiles.last_alerted_at "
            "FROM renter_profiles WHERE renter_profiles.user_id = users.id"
        )
    )
    op.drop_column("renter_profiles", "last_alerted_at")


def downgrade() -> None:
    op.add_column(
        "renter_profiles",
        sa.Column("last_alerted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.drop_column("users", "last_digest_at")
    op.drop_column("users", "last_lister_summary_at")
    op.drop_column("users", "alert_frequency")
    op.drop_table("alerts")
