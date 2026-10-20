"""Release: analytics events, referral codes and crash reports.

Revision ID: 0009
Revises: 0008
Create Date: 2026-10-20
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

# Kept in step with app/models/analytics.py.
ONCE_PER_USER = "name IN ('signed_up', 'profile_completed', 'first_swipe', 'first_match')"
ONCE_PER_LISTING = "name IN ('listing_published', 'listing_first_match', 'listing_filled')"
# No 0/O or 1/I/L, so a code read aloud or off a poster is typed right.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def upgrade() -> None:
    op.create_table(
        "events",
        sa.Column("id", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("name", sa.String(length=40), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("listing_id", sa.Uuid(), nullable=True),
        sa.Column("detail", sa.String(length=40), nullable=True),
        sa.Column("value", sa.Float(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_events_user_id_users"), ondelete="SET NULL"
        ),
        sa.ForeignKeyConstraint(
            ["listing_id"],
            ["listings.id"],
            name=op.f("fk_events_listing_id_listings"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_events")),
    )
    op.create_index("ix_events_name_created_at", "events", ["name", "created_at"])
    op.create_index(op.f("ix_events_user_id"), "events", ["user_id"])
    op.create_index(op.f("ix_events_listing_id"), "events", ["listing_id"])
    op.create_index(
        "uq_events_once_per_user",
        "events",
        ["user_id", "name"],
        unique=True,
        postgresql_where=sa.text(ONCE_PER_USER),
    )
    op.create_index(
        "uq_events_once_per_listing",
        "events",
        ["listing_id", "name"],
        unique=True,
        postgresql_where=sa.text(ONCE_PER_LISTING),
    )

    op.create_table(
        "crash_reports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("kind", sa.String(length=20), nullable=False),
        sa.Column("app_version", sa.String(length=20), nullable=False),
        sa.Column("os_version", sa.String(length=40), nullable=False),
        sa.Column("payload", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_crash_reports_user_id_users"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_crash_reports")),
    )
    op.create_index(op.f("ix_crash_reports_created_at"), "crash_reports", ["created_at"])

    op.add_column("users", sa.Column("referral_code", sa.String(length=8), nullable=True))
    op.add_column("users", sa.Column("referred_by_id", sa.Uuid(), nullable=True))
    op.add_column("users", sa.Column("referral_paid_at", sa.DateTime(timezone=True), nullable=True))
    op.create_foreign_key(
        op.f("fk_users_referred_by_id_users"),
        "users",
        "users",
        ["referred_by_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(op.f("ix_users_referred_by_id"), "users", ["referred_by_id"])
    # Every existing account gets a code: 7 characters from the alphabet above.
    picks = " || ".join(
        f"substr('{CODE_ALPHABET}', 1 + floor(random() * {len(CODE_ALPHABET)})::int, 1)"
        for _ in range(7)
    )
    op.execute(sa.text(f"UPDATE users SET referral_code = {picks}"))
    op.alter_column("users", "referral_code", nullable=False)
    op.create_unique_constraint(op.f("uq_users_referral_code"), "users", ["referral_code"])


def downgrade() -> None:
    op.drop_constraint(op.f("uq_users_referral_code"), "users", type_="unique")
    op.drop_index(op.f("ix_users_referred_by_id"), table_name="users")
    op.drop_constraint(op.f("fk_users_referred_by_id_users"), "users", type_="foreignkey")
    for name in ("referral_paid_at", "referred_by_id", "referral_code"):
        op.drop_column("users", name)
    op.drop_table("crash_reports")
    op.drop_table("events")
