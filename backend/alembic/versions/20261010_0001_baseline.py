"""Baseline: an empty migration that proves the migration pipeline works.

Revision ID: 0001
Revises:
Create Date: 2026-10-10
"""

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
