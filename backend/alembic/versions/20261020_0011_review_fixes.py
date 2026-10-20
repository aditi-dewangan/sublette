"""Fixes from the final review: reports outlive the accounts and content they
are about, one open report per reporter and target, and photo checks that
can't read a file wait a day before trying it again.

Revision ID: 0011
Revises: 0010
Create Date: 2026-10-20
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

OPEN_PER_REPORTER = "status = 'open' AND reporter_id IS NOT NULL"


def _refkey(column: str, table: str, ondelete: str) -> None:
    name = op.f(f"fk_reports_{column}_{table}")
    op.drop_constraint(name, "reports", type_="foreignkey")
    op.create_foreign_key(name, "reports", table, [column], ["id"], ondelete=ondelete)


def upgrade() -> None:
    op.add_column("reports", sa.Column("subject_email", sa.String(length=254), nullable=True))
    op.add_column("reports", sa.Column("target_id", sa.Uuid(), nullable=True))
    op.execute(
        sa.text(
            "UPDATE reports SET subject_email = users.email FROM users "
            "WHERE users.id = reports.subject_id"
        )
    )
    op.execute(
        sa.text(
            "UPDATE reports SET target_id = CASE target "
            "WHEN 'user' THEN subject_id WHEN 'listing' THEN listing_id ELSE message_id END"
        )
    )
    op.alter_column("reports", "subject_email", nullable=False)
    op.alter_column("reports", "target_id", nullable=False)
    op.alter_column("reports", "subject_id", nullable=True)
    _refkey("subject_id", "users", "SET NULL")
    _refkey("listing_id", "listings", "SET NULL")
    _refkey("message_id", "messages", "SET NULL")
    op.create_index(op.f("ix_reports_subject_email"), "reports", ["subject_email"])
    # Two identical reports sent at once can't both be filed.
    op.execute(
        sa.text(
            "DELETE FROM reports r USING reports older WHERE r.status = 'open' "
            "AND older.status = 'open' AND r.reporter_id = older.reporter_id "
            "AND r.target = older.target AND r.target_id = older.target_id "
            "AND r.created_at > older.created_at"
        )
    )
    op.create_index(
        "uq_reports_open_per_reporter",
        "reports",
        ["reporter_id", "target", "target_id"],
        unique=True,
        postgresql_where=sa.text(OPEN_PER_REPORTER),
    )

    op.add_column(
        "listing_photos", sa.Column("hash_checked_at", sa.DateTime(timezone=True), nullable=True)
    )


def downgrade() -> None:
    op.drop_column("listing_photos", "hash_checked_at")
    op.drop_index("uq_reports_open_per_reporter", table_name="reports")
    op.drop_index(op.f("ix_reports_subject_email"), table_name="reports")
    op.execute(sa.text("DELETE FROM reports WHERE subject_id IS NULL"))
    _refkey("message_id", "messages", "CASCADE")
    _refkey("listing_id", "listings", "CASCADE")
    _refkey("subject_id", "users", "CASCADE")
    op.alter_column("reports", "subject_id", nullable=False)
    op.drop_column("reports", "target_id")
    op.drop_column("reports", "subject_email")
