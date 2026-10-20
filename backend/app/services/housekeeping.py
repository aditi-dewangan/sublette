"""Jobs the server runs on its own, every few minutes, on a background thread.

* Listings whose expiry date or move-out date has passed become "expired",
  and their listers get a push asking whether the place is still free.
* Listing photos get a fingerprint (SHA-256), and one photo on two people's
  listings goes to the review queue as a scam flag.
* Photos uploaded and never attached to a profile or listing (an editor
  closed without saving) are deleted after a day.
* Old rate-limit counts and expired sign-in codes are deleted.

Every run is safe to repeat, and only one server process runs it at a time
(a PostgreSQL advisory lock). The deck already hides an expired listing on
the day, so nothing depends on the run being punctual.
"""

import hashlib
import logging
import threading
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

from sqlalchemy import Engine, delete, or_, select, text, update
from sqlalchemy.orm import Session

from app.clock import local_today
from app.models import EmailCode, Listing, ListingPhoto, RateLimitHit, Report, Upload, User
from app.seed_fake import SEED_PREFIX
from app.services.push import PushDispatcher, PushNote
from app.services.storage import PhotoStorage

logger = logging.getLogger("sublette.housekeeping")

# Any number, the same in every process: "the housekeeping lock".
LOCK_ID = 80_08_2026
ABANDONED_AFTER = timedelta(days=1)
# The longest rate-limit window is a day.
KEEP_RATE_LIMIT_HITS = timedelta(days=2)
PHOTOS_PER_RUN = 200
RETRY_UNREADABLE_AFTER = timedelta(days=1)
UPLOADS_PER_RUN = 500


@dataclass
class Summary:
    ran: bool = True
    expired: list[uuid.UUID] = field(default_factory=list)
    photos_checked: int = 0
    flagged: list[uuid.UUID] = field(default_factory=list)
    uploads_deleted: int = 0


def run_once(engine: Engine, storage: PhotoStorage, push: PushDispatcher, now: datetime) -> Summary:
    """One run of every job. Skipped if another process is running it."""
    with engine.connect() as lock:
        if not lock.scalar(text("SELECT pg_try_advisory_lock(:id)"), {"id": LOCK_ID}):
            return Summary(ran=False)
        try:
            with Session(engine) as session:
                summary = Summary()
                summary.expired = expire_listings(session, push, now)
                summary.photos_checked, summary.flagged = check_photos(session, storage, now)
                summary.uploads_deleted = delete_abandoned_uploads(session, storage, now)
                prune(session, now)
                return summary
        finally:
            lock.execute(text("SELECT pg_advisory_unlock(:id)"), {"id": LOCK_ID})
            lock.commit()


def expire_listings(session: Session, push: PushDispatcher, now: datetime) -> list[uuid.UUID]:
    today = local_today(now)
    rows = session.execute(
        update(Listing)
        .where(
            Listing.status.in_(("active", "paused")),
            or_(Listing.end_date < today, Listing.expires_on < today),
        )
        .values(status="expired")
        .returning(Listing.id, Listing.owner_id, Listing.end_date)
    ).all()
    session.commit()
    for listing_id, owner_id, end_date in rows:
        if end_date < today:
            continue  # over, so there is nothing to renew
        note = PushNote(
            title="Is your place still free?",
            body="Your listing expired after its move-in date. Renew it to keep it in decks.",
            data={"kind": "listing_expired", "listing_id": str(listing_id), "role": "lister"},
        )
        push.deliver(session, owner_id, note)
    return [row.id for row in rows]


def check_photos(
    session: Session, storage: PhotoStorage, now: datetime
) -> tuple[int, list[uuid.UUID]]:
    """Fingerprint photos of published listings, then flag any listing that
    shares a photo with another person's listing."""
    # Fake listings from `make seed-fake` share a few sample pictures on purpose.
    real_owner = User.email.not_like(f"{SEED_PREFIX}%")
    photos = session.scalars(
        select(ListingPhoto)
        .join(Listing, Listing.id == ListingPhoto.listing_id)
        .join(User, User.id == Listing.owner_id)
        .where(
            ListingPhoto.content_hash.is_(None),
            Listing.status != "draft",
            real_owner,
            # A file that couldn't be read waits a day, so it can't hold up the rest.
            or_(
                ListingPhoto.hash_checked_at.is_(None),
                ListingPhoto.hash_checked_at < now - RETRY_UNREADABLE_AFTER,
            ),
        )
        .order_by(ListingPhoto.hash_checked_at.nulls_first(), ListingPhoto.id)
        .limit(PHOTOS_PER_RUN)
    ).all()
    hashes = set()
    checked = 0
    for photo in photos:
        data = storage.read(photo.key)
        if not data:
            photo.hash_checked_at = now
            continue
        photo.content_hash = hashlib.sha256(data).hexdigest()
        hashes.add(photo.content_hash)
        checked += 1
    session.commit()
    if not hashes:
        return checked, []

    # hash -> owner -> that owner's listings with the photo
    found: dict[str, dict[uuid.UUID, list[Listing]]] = defaultdict(lambda: defaultdict(list))
    for photo, listing in session.execute(
        select(ListingPhoto, Listing)
        .join(Listing, Listing.id == ListingPhoto.listing_id)
        .join(User, User.id == Listing.owner_id)
        .where(ListingPhoto.content_hash.in_(hashes), Listing.status != "draft", real_owner)
    ).unique():
        if listing not in found[photo.content_hash][listing.owner_id]:
            found[photo.content_hash][listing.owner_id].append(listing)

    flagged = []
    for owners in found.values():
        if len(owners) < 2:
            continue  # one person reusing their own photos is fine
        for owner_id, listings in owners.items():
            others = [
                other for who, theirs in owners.items() if who != owner_id for other in theirs
            ]
            for listing in listings:
                if _flag_duplicate(session, listing, others, now):
                    flagged.append(listing.id)
    session.commit()
    return checked, flagged


def _flag_duplicate(session: Session, listing: Listing, others: list[Listing], now) -> bool:
    already = session.scalar(
        select(Report.id).where(
            Report.listing_id == listing.id,
            Report.reason == "duplicate_photo",
            Report.status == "open",
        )
    )
    if already is not None:
        return False
    # Ids only: another person's email must not outlive their account in this report.
    shown = ", ".join(str(other.id) for other in others[:5])
    more = f" and {len(others) - 5} more" if len(others) > 5 else ""
    session.add(
        Report(
            id=uuid.uuid4(),
            source="automatic",
            subject_id=listing.owner_id,
            subject_email=listing.owner.email,
            target="listing",
            target_id=listing.id,
            listing_id=listing.id,
            reason="duplicate_photo",
            details="A photo on this listing is also on another person's listing.",
            excerpt=f"Same photo as listing {shown}{more}",
            status="open",
            created_at=now,
        )
    )
    return True


def delete_abandoned_uploads(session: Session, storage: PhotoStorage, now: datetime) -> int:
    """Uploads older than a day: delete the file unless something uses it.
    Either way the record of the upload goes."""
    old = session.scalars(
        select(Upload.key).where(Upload.created_at < now - ABANDONED_AFTER).limit(UPLOADS_PER_RUN)
    ).all()
    if not old:
        return 0
    used = set(
        session.scalars(select(ListingPhoto.key).where(ListingPhoto.key.in_(old))).all()
    ) | set(session.scalars(select(User.photo_key).where(User.photo_key.in_(old))).all())
    deleted = 0
    for key in old:
        if key not in used:
            storage.delete(key)
            deleted += 1
    session.execute(delete(Upload).where(Upload.key.in_(old)))
    session.commit()
    return deleted


def prune(session: Session, now: datetime) -> None:
    session.execute(
        delete(RateLimitHit).where(RateLimitHit.created_at < now - KEEP_RATE_LIMIT_HITS)
    )
    session.execute(delete(EmailCode).where(EmailCode.expires_at < now - timedelta(days=1)))
    session.commit()


class Housekeeper:
    """Runs `run_once` every `every_s` seconds on a thread until stopped."""

    def __init__(
        self, engine: Engine, storage: PhotoStorage, push: PushDispatcher, every_s: int
    ) -> None:
        self._args = (engine, storage, push)
        self._every_s = every_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, name="housekeeping", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=30)

    def _loop(self) -> None:
        # A short pause first, so a restart doesn't compete with start-up.
        pause = min(30, self._every_s)
        while not self._stop.wait(pause):
            pause = self._every_s
            try:
                summary = run_once(*self._args, datetime.now(UTC))
                if summary.expired or summary.flagged or summary.uploads_deleted:
                    logger.info(
                        "Housekeeping: %d expired, %d flagged, %d uploads deleted",
                        len(summary.expired),
                        len(summary.flagged),
                        summary.uploads_deleted,
                    )
            except Exception:
                # The database may be down; try again next time.
                logger.exception("Housekeeping failed")
