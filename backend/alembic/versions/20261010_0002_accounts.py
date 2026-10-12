"""Accounts: schools, users, sign-in codes and rate-limit counters.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-10
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    op.create_table(
        "email_codes",
        sa.Column("email", sa.String(length=254), nullable=False),
        sa.Column("code_hash", sa.String(length=64), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("email", name=op.f("pk_email_codes")),
    )
    op.create_table(
        "rate_limit_hits",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("bucket", sa.String(length=300), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rate_limit_hits")),
    )
    op.create_index(
        "ix_rate_limit_hits_bucket_created_at",
        "rate_limit_hits",
        ["bucket", "created_at"],
        unique=False,
    )
    op.create_table(
        "schools",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=200), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_schools")),
    )
    op.create_table(
        "school_domains",
        sa.Column("domain", sa.String(length=253), nullable=False),
        sa.Column("school_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(
            ["school_id"],
            ["schools.id"],
            name=op.f("fk_school_domains_school_id_schools"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("domain", name=op.f("pk_school_domains")),
    )
    op.create_index(
        op.f("ix_school_domains_school_id"), "school_domains", ["school_id"], unique=False
    )
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.String(length=254), nullable=False),
        sa.Column("school_id", sa.Uuid(), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("first_name", sa.String(length=50), nullable=True),
        sa.Column("year", sa.String(length=20), nullable=True),
        sa.Column("program", sa.String(length=100), nullable=True),
        sa.Column("bio", sa.String(length=160), nullable=True),
        sa.Column("photo_key", sa.String(length=200), nullable=True),
        sa.Column("gender", sa.String(length=20), nullable=True),
        sa.Column("smokes", sa.Boolean(), nullable=True),
        sa.Column("has_pets", sa.Boolean(), nullable=True),
        sa.Column("status", sa.String(length=20), server_default="active", nullable=False),
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
            ["school_id"], ["schools.id"], name=op.f("fk_users_school_id_schools")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
        sa.UniqueConstraint("email", name=op.f("uq_users_email")),
    )
    op.create_index(op.f("ix_users_school_id"), "users", ["school_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_users_school_id"), table_name="users")
    op.drop_table("users")
    op.drop_index(op.f("ix_school_domains_school_id"), table_name="school_domains")
    op.drop_table("school_domains")
    op.drop_table("schools")
    op.drop_index("ix_rate_limit_hits_bucket_created_at", table_name="rate_limit_hits")
    op.drop_table("rate_limit_hits")
    op.drop_table("email_codes")
