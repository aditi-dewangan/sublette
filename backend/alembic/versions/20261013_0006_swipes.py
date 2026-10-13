"""Swipes, matches and saved listings; the notify-me choice on renter profiles.

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-13
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def _created_at() -> sa.Column:
    return sa.Column(
        "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def _user_fk(column: str, table: str) -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        [column], ["users.id"], name=op.f(f"fk_{table}_{column}_users"), ondelete="CASCADE"
    )


def _listing_fk(table: str) -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        ["listing_id"],
        ["listings.id"],
        name=op.f(f"fk_{table}_listing_id_listings"),
        ondelete="CASCADE",
    )


def upgrade() -> None:
    op.create_table(
        "swipes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=True),
        sa.Column("side", sa.String(length=10), nullable=False),
        sa.Column("action", sa.String(length=10), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=False),
        sa.Column("renter_id", sa.Uuid(), nullable=False),
        sa.Column("swiper_id", sa.Uuid(), nullable=False),
        _created_at(),
        _listing_fk("swipes"),
        _user_fk("renter_id", "swipes"),
        _user_fk("swiper_id", "swipes"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_swipes")),
        sa.UniqueConstraint("client_id", name=op.f("uq_swipes_client_id")),
        sa.UniqueConstraint(
            "side", "listing_id", "renter_id", name=op.f("uq_swipes_side_listing_id_renter_id")
        ),
    )
    for column in ("listing_id", "renter_id", "swiper_id"):
        op.create_index(op.f(f"ix_swipes_{column}"), "swipes", [column], unique=False)

    op.create_table(
        "matches",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=False),
        sa.Column("renter_id", sa.Uuid(), nullable=False),
        sa.Column("lister_id", sa.Uuid(), nullable=False),
        _created_at(),
        _listing_fk("matches"),
        _user_fk("renter_id", "matches"),
        _user_fk("lister_id", "matches"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_matches")),
        sa.UniqueConstraint(
            "listing_id", "renter_id", name=op.f("uq_matches_listing_id_renter_id")
        ),
    )
    for column in ("listing_id", "renter_id", "lister_id"):
        op.create_index(op.f(f"ix_matches_{column}"), "matches", [column], unique=False)

    op.create_table(
        "saved_listings",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=False),
        _created_at(),
        _user_fk("user_id", "saved_listings"),
        _listing_fk("saved_listings"),
        sa.PrimaryKeyConstraint("user_id", "listing_id", name=op.f("pk_saved_listings")),
    )

    op.add_column(
        "renter_profiles",
        sa.Column("notify_new_listings", sa.Boolean(), server_default="false", nullable=False),
    )


def downgrade() -> None:
    op.drop_column("renter_profiles", "notify_new_listings")
    op.drop_table("saved_listings")
    op.drop_table("matches")
    op.drop_table("swipes")
