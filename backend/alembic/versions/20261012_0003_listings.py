"""Listings, their photos, and photos kept in the database.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-12
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    # Listings have locations. PostGIS is used for distance queries from phase 4;
    # turning it on now makes a database without it fail here, early.
    op.execute("CREATE EXTENSION IF NOT EXISTS postgis")
    op.create_table(
        "stored_files",
        sa.Column("key", sa.String(length=200), nullable=False),
        sa.Column("content_type", sa.String(length=50), nullable=False),
        sa.Column("data", sa.LargeBinary(), nullable=False),
        sa.Column("size", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("key", name=op.f("pk_stored_files")),
    )
    op.create_table(
        "listings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.String(length=20), server_default="draft", nullable=False),
        sa.Column("address", sa.String(length=300), nullable=True),
        sa.Column("latitude", sa.Float(), nullable=True),
        sa.Column("longitude", sa.Float(), nullable=True),
        sa.Column("public_latitude", sa.Float(), nullable=True),
        sa.Column("public_longitude", sa.Float(), nullable=True),
        sa.Column("rent_cents", sa.Integer(), nullable=True),
        sa.Column("deposit_cents", sa.Integer(), server_default="0", nullable=False),
        sa.Column("utilities_included", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("start_date", sa.Date(), nullable=True),
        sa.Column("end_date", sa.Date(), nullable=True),
        sa.Column("space_type", sa.String(length=20), nullable=True),
        sa.Column("bedrooms", sa.Integer(), nullable=True),
        sa.Column("bathroom", sa.String(length=10), nullable=True),
        sa.Column("furnished", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("laundry", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("parking", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("housemates_staying", sa.Integer(), nullable=True),
        sa.Column("housemates_note", sa.String(length=140), nullable=True),
        sa.Column("pets_allowed", sa.Boolean(), nullable=True),
        sa.Column("smoking_allowed", sa.Boolean(), nullable=True),
        sa.Column("gender_preference", sa.String(length=10), server_default="any", nullable=False),
        sa.Column("same_school_only", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("min_stay_days", sa.Integer(), server_default="0", nullable=False),
        sa.Column("landlord_consent", sa.Boolean(), nullable=True),
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
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["users.id"], name=op.f("fk_listings_owner_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_listings")),
    )
    op.create_index(op.f("ix_listings_owner_id"), "listings", ["owner_id"], unique=False)
    op.create_table(
        "listing_photos",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=False),
        sa.Column("key", sa.String(length=200), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(
            ["listing_id"],
            ["listings.id"],
            name=op.f("fk_listing_photos_listing_id_listings"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_listing_photos")),
        sa.UniqueConstraint("key", name=op.f("uq_listing_photos_key")),
    )
    op.create_index(
        op.f("ix_listing_photos_listing_id"), "listing_photos", ["listing_id"], unique=False
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_listing_photos_listing_id"), table_name="listing_photos")
    op.drop_table("listing_photos")
    op.drop_index(op.f("ix_listings_owner_id"), table_name="listings")
    op.drop_table("listings")
    op.drop_table("stored_files")
