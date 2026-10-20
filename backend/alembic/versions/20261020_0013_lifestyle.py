"""Housemate lifestyle (issue #20): five optional answers on each account
(the renter's own) and each listing (the housemates staying).

Revision ID: 0013
Revises: 0012
Create Date: 2026-10-20
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

QUESTIONS = ("sleep_schedule", "tidiness", "guests", "home_daytime", "home_vibe")


def upgrade() -> None:
    for table in ("users", "listings"):
        for name in QUESTIONS:
            op.add_column(table, sa.Column(name, sa.String(length=12), nullable=True))


def downgrade() -> None:
    for table in ("users", "listings"):
        for name in QUESTIONS:
            op.drop_column(table, name)
