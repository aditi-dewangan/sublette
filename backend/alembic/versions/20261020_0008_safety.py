"""Trust and safety: reports, blocks, uploads, listing expiry, suspension
reasons, terms acceptance and photo fingerprints.

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-20
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

# Days a live listing stays up once its move-in date is near, and after each renewal.
RENEW_DAYS = 14


def _created_at() -> sa.Column:
    return sa.Column(
        "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def _user_fk(table: str, column: str, ondelete: str = "CASCADE") -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        [column], ["users.id"], name=op.f(f"fk_{table}_{column}_users"), ondelete=ondelete
    )


def upgrade() -> None:
    op.create_table(
        "reports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("source", sa.String(length=20), nullable=False),
        sa.Column("reporter_id", sa.Uuid(), nullable=True),
        sa.Column("subject_id", sa.Uuid(), nullable=False),
        sa.Column("target", sa.String(length=20), nullable=False),
        sa.Column("listing_id", sa.Uuid(), nullable=True),
        sa.Column("message_id", sa.Uuid(), nullable=True),
        sa.Column("reason", sa.String(length=30), nullable=False),
        sa.Column("details", sa.String(length=500), nullable=True),
        sa.Column("excerpt", sa.String(length=2000), nullable=True),
        sa.Column("status", sa.String(length=20), server_default="open", nullable=False),
        sa.Column("resolution", sa.String(length=300), nullable=True),
        _created_at(),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        _user_fk("reports", "reporter_id", "SET NULL"),
        _user_fk("reports", "subject_id"),
        sa.ForeignKeyConstraint(
            ["listing_id"],
            ["listings.id"],
            name=op.f("fk_reports_listing_id_listings"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["message_id"],
            ["messages.id"],
            name=op.f("fk_reports_message_id_messages"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_reports")),
    )
    op.create_index("ix_reports_status_created_at", "reports", ["status", "created_at"])
    op.create_index(op.f("ix_reports_subject_id"), "reports", ["subject_id"])
    op.create_index(op.f("ix_reports_reporter_id"), "reports", ["reporter_id"])
    op.create_index(op.f("ix_reports_listing_id"), "reports", ["listing_id"])
    op.create_index(op.f("ix_reports_message_id"), "reports", ["message_id"])

    op.create_table(
        "blocks",
        sa.Column("blocker_id", sa.Uuid(), nullable=False),
        sa.Column("blocked_id", sa.Uuid(), nullable=False),
        _created_at(),
        _user_fk("blocks", "blocker_id"),
        _user_fk("blocks", "blocked_id"),
        sa.PrimaryKeyConstraint("blocker_id", "blocked_id", name=op.f("pk_blocks")),
        sa.CheckConstraint("blocker_id <> blocked_id", name=op.f("ck_blocks_not_self")),
    )
    op.create_index(op.f("ix_blocks_blocked_id"), "blocks", ["blocked_id"])

    op.create_table(
        "uploads",
        sa.Column("key", sa.String(length=200), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        _created_at(),
        _user_fk("uploads", "user_id"),
        sa.PrimaryKeyConstraint("key", name=op.f("pk_uploads")),
    )
    op.create_index(op.f("ix_uploads_user_id"), "uploads", ["user_id"])
    op.create_index(op.f("ix_uploads_created_at"), "uploads", ["created_at"])

    op.add_column("users", sa.Column("suspended_reason", sa.String(length=300), nullable=True))
    op.add_column("users", sa.Column("suspended_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("users", sa.Column("terms_version", sa.String(length=20), nullable=True))
    op.add_column(
        "users", sa.Column("terms_accepted_at", sa.DateTime(timezone=True), nullable=True)
    )

    op.add_column("listings", sa.Column("expires_on", sa.Date(), nullable=True))
    op.add_column("listings", sa.Column("removed_reason", sa.String(length=300), nullable=True))
    # Live listings get the same expiry date a fresh publish would give them.
    op.execute(
        sa.text(
            "UPDATE listings SET expires_on = LEAST(end_date, "
            f"GREATEST(start_date, CURRENT_DATE + {RENEW_DAYS})) "
            "WHERE status IN ('active', 'paused') AND start_date IS NOT NULL "
            "AND end_date IS NOT NULL"
        )
    )

    op.add_column("listing_photos", sa.Column("content_hash", sa.String(length=64), nullable=True))
    op.create_index(op.f("ix_listing_photos_content_hash"), "listing_photos", ["content_hash"])


def downgrade() -> None:
    op.drop_index(op.f("ix_listing_photos_content_hash"), table_name="listing_photos")
    op.drop_column("listing_photos", "content_hash")
    op.execute(sa.text("UPDATE listings SET status = 'paused' WHERE status = 'removed'"))
    op.drop_column("listings", "removed_reason")
    op.drop_column("listings", "expires_on")
    for name in ("terms_accepted_at", "terms_version", "suspended_at", "suspended_reason"):
        op.drop_column("users", name)
    op.drop_table("uploads")
    op.drop_table("blocks")
    op.drop_table("reports")
