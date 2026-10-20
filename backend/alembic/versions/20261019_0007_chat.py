"""Chat, the sublet checklist, filled confirmations and push device tokens.

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-19
"""

import sqlalchemy as sa

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | tuple[str, ...] | None = None
depends_on: str | tuple[str, ...] | None = None

CHECKLIST = ("tour_done", "landlord_consent_confirmed", "dates_agreed", "sublease_signed")
MATCH_TIMES = (
    "checklist_updated_at",
    "renter_filled_at",
    "lister_filled_at",
    "last_message_at",
)

# The `seq` of the last message each side has seen.
READ_UP_TO = ("renter_read_seq", "lister_read_seq")


def _created_at() -> sa.Column:
    return sa.Column(
        "created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def upgrade() -> None:
    op.create_table(
        "messages",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("seq", sa.BigInteger(), sa.Identity(always=True), nullable=False),
        sa.Column("client_id", sa.Uuid(), nullable=True),
        sa.Column("match_id", sa.Uuid(), nullable=False),
        sa.Column("sender_id", sa.Uuid(), nullable=False),
        sa.Column("body", sa.String(length=2000), nullable=False),
        _created_at(),
        sa.ForeignKeyConstraint(
            ["match_id"],
            ["matches.id"],
            name=op.f("fk_messages_match_id_matches"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["sender_id"],
            ["users.id"],
            name=op.f("fk_messages_sender_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_messages")),
        sa.UniqueConstraint("client_id", name=op.f("uq_messages_client_id")),
        sa.UniqueConstraint("seq", name=op.f("uq_messages_seq")),
    )
    op.create_index(op.f("ix_messages_match_id_seq"), "messages", ["match_id", "seq"], unique=False)
    op.create_index(op.f("ix_messages_sender_id"), "messages", ["sender_id"], unique=False)

    op.create_table(
        "device_tokens",
        sa.Column("token", sa.String(length=200), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("environment", sa.String(length=20), nullable=False),
        _created_at(),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_device_tokens_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("token", name=op.f("pk_device_tokens")),
    )
    op.create_index(op.f("ix_device_tokens_user_id"), "device_tokens", ["user_id"], unique=False)

    for name in CHECKLIST:
        op.add_column(
            "matches", sa.Column(name, sa.Boolean(), server_default="false", nullable=False)
        )
    for name in MATCH_TIMES:
        op.add_column("matches", sa.Column(name, sa.DateTime(timezone=True), nullable=True))
    for name in READ_UP_TO:
        op.add_column(
            "matches", sa.Column(name, sa.BigInteger(), server_default="0", nullable=False)
        )

    op.add_column(
        "users",
        sa.Column("completed_sublets", sa.Integer(), server_default="0", nullable=False),
    )
    op.add_column(
        "renter_profiles",
        sa.Column("last_alerted_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("renter_profiles", "last_alerted_at")
    op.drop_column("users", "completed_sublets")
    for name in (*READ_UP_TO, *MATCH_TIMES, *CHECKLIST):
        op.drop_column("matches", name)
    op.drop_table("device_tokens")
    op.drop_table("messages")
