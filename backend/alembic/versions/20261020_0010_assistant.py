"""The assistant's query log, for review.

Revision ID: 0010
Revises: 0009
Create Date: 2026-10-20
"""

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    op.create_table(
        "assistant_queries",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("message", sa.String(length=500), nullable=False),
        sa.Column("understood", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("listing_ids", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("backend", sa.String(length=20), nullable=False),
        sa.Column("fell_back", sa.Boolean(), server_default="false", nullable=False),
        sa.Column("problem", sa.String(length=200), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_assistant_queries_user_id_users"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_assistant_queries")),
    )
    op.create_index(op.f("ix_assistant_queries_created_at"), "assistant_queries", ["created_at"])


def downgrade() -> None:
    op.drop_table("assistant_queries")
