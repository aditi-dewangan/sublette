"""Fake listers, listings and renters for trying the deck and timing it.

    python -m app.seed_fake                 # 1,000 listings and 200 renters
    python -m app.seed_fake --no-photos     # skip the photo files
    python -m app.seed_fake --remove        # take them all out again

(`make seed-fake` runs the first.) Every fake account's email starts with
`seed-`, so running it again replaces the last batch and never touches real
accounts. Nobody can sign in as a fake account without its email inbox.

Refuses to run in production.

Three campuses in three cities, so nothing depends on one place. They are
picked by email domain from the seeded list of schools.
"""

import argparse
import math
import random
import sys
import uuid
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.config import Settings, get_settings
from app.db import make_engine
from app.models import Listing, ListingPhoto, RenterProfile, SchoolDomain, StoredFile, User
from app.services.geo import EARTH_RADIUS_M, offset_point
from app.services.schools import seed_schools
from app.services.storage import FileStore

SEED_PREFIX = "seed-"
PHOTO_DIR = Path(__file__).parent / "data" / "seed_photos"
PHOTOS_PER_LISTING = 4


@dataclass(frozen=True)
class Campus:
    domain: str
    latitude: float
    longitude: float


CAMPUSES = (
    Campus("uw.edu", 47.6553, -122.3035),
    Campus("utexas.edu", 30.2849, -97.7341),
    Campus("bu.edu", 42.3505, -71.1054),
)

FIRST_NAMES = (
    "Alex", "Sam", "Jordan", "Priya", "Mei", "Diego", "Amara", "Noah", "Lena", "Omar",
    "Hana", "Leo", "Zoe", "Ravi", "Ines", "Kai", "Nia", "Theo", "Yara", "Eli",
)  # fmt: skip
PROGRAMS = ("Informatics", "Biology", "Economics", "Design", "Physics", "History", "Nursing")


@dataclass
class SeedResult:
    listings: int
    renters: int
    photos_stored: int
    renter_emails: list[str]


def _point_near(rng: random.Random, campus: Campus, max_m: float) -> tuple[float, float]:
    """A random point within `max_m` of the campus, spread evenly over the area."""
    distance = max_m * math.sqrt(rng.random())
    bearing = rng.uniform(0, 2 * math.pi)
    d_lat = distance * math.cos(bearing) / EARTH_RADIUS_M
    d_lng = (
        distance * math.sin(bearing) / (EARTH_RADIUS_M * math.cos(math.radians(campus.latitude)))
    )
    return campus.latitude + math.degrees(d_lat), campus.longitude + math.degrees(d_lng)


def _user(rng: random.Random, email: str, school_id: uuid.UUID, now: datetime) -> User:
    return User(
        id=uuid.uuid4(),
        email=email,
        school_id=school_id,
        verified_at=now,
        first_name=rng.choice(FIRST_NAMES),
        year=rng.choice(("sophomore", "junior", "senior", "graduate")),
        program=rng.choice(PROGRAMS),
        gender=rng.choices(("woman", "man", "nonbinary", None), weights=(45, 40, 8, 7))[0],
        smokes=rng.random() < 0.08,
        has_pets=rng.random() < 0.15,
        status="active",
    )


def _listing(
    rng: random.Random, owner: User, campus: Campus, today: date, now: datetime
) -> Listing:
    latitude, longitude = _point_near(rng, campus, 6_000)
    public_latitude, public_longitude = offset_point(latitude, longitude, rng)
    space_type = rng.choices(("private_room", "entire_unit", "shared_room"), weights=(6, 3, 1))[0]
    shared = space_type != "entire_unit"
    staying = rng.randint(1, 4) if shared else 0
    start = today + timedelta(days=rng.randint(0, 120))
    end = start + timedelta(days=rng.randint(30, 240))
    gender_preference = (
        rng.choices(("any", "women", "men"), weights=(7, 2, 1))[0] if shared else "any"
    )
    return Listing(
        id=uuid.uuid4(),
        owner_id=owner.id,
        status="active",
        address=f"{rng.randint(100, 9999)} Example St, Unit {rng.randint(1, 40)}",
        latitude=latitude,
        longitude=longitude,
        public_latitude=public_latitude,
        public_longitude=public_longitude,
        rent_cents=rng.randrange(60_000, 250_000, 2_500),
        deposit_cents=rng.choice((0, 25_000, 50_000)),
        utilities_included=rng.random() < 0.4,
        start_date=start,
        end_date=end,
        space_type=space_type,
        bedrooms=rng.randint(1, 4) if shared else rng.randint(0, 2),
        bathroom=rng.choice(("private", "shared")) if shared else "private",
        furnished=rng.random() < 0.7,
        laundry=rng.random() < 0.5,
        parking=rng.random() < 0.3,
        housemates_staying=staying,
        household_gender=rng.choices(("women", "men", "mixed"), weights=(4, 3, 3))[0]
        if staying
        else None,
        pets_allowed=rng.random() < 0.35,
        smoking_allowed=rng.random() < 0.1,
        gender_preference=gender_preference,
        same_school_only=rng.random() < 0.15,
        min_stay_days=rng.choice((0, 0, 30, 60)),
        landlord_consent=True,
        published_at=now - timedelta(minutes=rng.randint(1, 60 * 24 * 30)),
    )


def _preferences(rng: random.Random) -> list[dict]:
    def importance() -> str:
        return rng.choices(("must", "nice", "off"), weights=(1, 3, 4))[0]

    types = rng.sample(("entire_unit", "private_room", "shared_room"), rng.randint(1, 3))
    preferences = [{"field": "space_type", "value": types, "importance": importance()}]
    for field in ("private_bathroom", "furnished", "laundry", "parking", "pet_free", "smoke_free"):
        preferences.append({"field": field, "value": True, "importance": importance()})
    preferences.append(
        {"field": "housemate_count", "value": rng.randint(1, 4), "importance": importance()}
    )
    if rng.random() < 0.3:
        preferences.append(
            {
                "field": "housemate_gender",
                "value": rng.choice(("women", "men")),
                "importance": "nice",
            }
        )
    return preferences


def _renter_profile(rng: random.Random, user: User, campus: Campus, today: date) -> RenterProfile:
    start = today + timedelta(days=rng.randint(0, 90))
    pin_latitude, pin_longitude = _point_near(rng, campus, 1_500)
    return RenterProfile(
        user_id=user.id,
        start_date=start,
        end_date=start + timedelta(days=rng.randint(45, 150)),
        flexibility_days=rng.choice((0, 3, 7, 14)),
        max_rent_cents=rng.randrange(80_000, 220_000, 5_000),
        preferences=_preferences(rng),
        pin_latitude=pin_latitude,
        pin_longitude=pin_longitude,
        radius_m=rng.choice((2_000, 3_000, 5_000, 8_000)),
    )


def seed_photo_files() -> list[bytes]:
    """The sample room pictures. Empty when the folder is missing."""
    if not PHOTO_DIR.is_dir():
        return []
    return [path.read_bytes() for path in sorted(PHOTO_DIR.glob("*.jpg"))]


def remove_fake_data(session: Session) -> int:
    """Delete every fake account and what hangs off it. Returns how many accounts."""
    owners = select(User.id).where(User.email.like(f"{SEED_PREFIX}%"))
    keys = session.scalars(
        select(ListingPhoto.key).join(Listing).where(Listing.owner_id.in_(owners))
    ).all()
    if keys:
        session.execute(delete(StoredFile).where(StoredFile.key.in_(keys)))
    result = session.execute(delete(User).where(User.email.like(f"{SEED_PREFIX}%")))
    return result.rowcount or 0


def seed_fake_data(
    session: Session,
    *,
    listings: int = 1_000,
    renters: int = 200,
    today: date | None = None,
    store: FileStore | None = None,
    rng: random.Random | None = None,
) -> SeedResult:
    """Replace the fake data with a new batch. Listings and renters are spread
    evenly over the three campuses. Photo files are written only when a store
    is given (photos kept by this server) and the sample pictures exist."""
    rng = rng or random.Random(2027)
    now = datetime.now(UTC)
    today = today or now.date()
    remove_fake_data(session)
    seed_schools(session)

    school_ids = {}
    for campus in CAMPUSES:
        domain = session.get(SchoolDomain, campus.domain)
        if domain is None:
            raise RuntimeError(f"{campus.domain} is not in app/data/schools.json")
        school_ids[campus.domain] = domain.school_id

    pictures = seed_photo_files() if store is not None else []
    stored = 0
    users: list[User] = []
    rows: list[Listing] = []
    photos: list[ListingPhoto] = []
    owners: dict[str, User] = {}
    for index in range(listings):
        campus = CAMPUSES[index % len(CAMPUSES)]
        # About three listings per lister.
        if (index // len(CAMPUSES)) % 3 == 0:
            owners[campus.domain] = _user(
                rng, f"{SEED_PREFIX}lister-{index}@{campus.domain}", school_ids[campus.domain], now
            )
            users.append(owners[campus.domain])
        owner = owners[campus.domain]
        listing = _listing(rng, owner, campus, today, now)
        rows.append(listing)
        for position in range(PHOTOS_PER_LISTING):
            key = f"listings/{owner.id}/{uuid.uuid4().hex}.jpg"
            photos.append(ListingPhoto(listing_id=listing.id, key=key, position=position))
            if pictures:
                store.put(key, "image/jpeg", pictures[(index + position) % len(pictures)])
                stored += 1

    renter_emails = []
    profiles = []
    for index in range(renters):
        campus = CAMPUSES[index % len(CAMPUSES)]
        email = f"{SEED_PREFIX}renter-{index}@{campus.domain}"
        user = _user(rng, email, school_ids[campus.domain], now)
        users.append(user)
        profiles.append(_renter_profile(rng, user, campus, today))
        renter_emails.append(email)

    session.add_all(users)
    session.flush()
    session.add_all(rows)
    session.flush()
    session.add_all(photos)
    session.add_all(profiles)
    session.flush()
    return SeedResult(len(rows), len(profiles), stored, renter_emails)


def main(argv: list[str] | None = None, settings: Settings | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--listings", type=int, default=1_000)
    parser.add_argument("--renters", type=int, default=200)
    parser.add_argument("--no-photos", action="store_true", help="don't write photo files")
    parser.add_argument("--remove", action="store_true", help="delete the fake data and stop")
    args = parser.parse_args(argv)

    settings = settings or get_settings()
    if settings.env == "production":
        print("Refusing to add fake data to production.", file=sys.stderr)
        return 2

    engine = make_engine(settings)
    try:
        with Session(engine) as session:
            if args.remove:
                removed = remove_fake_data(session)
                session.commit()
                print(f"Removed {removed} fake account(s) and everything they made.")
                return 0
            store = None
            if not args.no_photos:
                store = _photo_store(settings, engine)
            result = seed_fake_data(
                session, listings=args.listings, renters=args.renters, store=store
            )
            session.commit()
    finally:
        engine.dispose()

    print(f"Added {result.listings} listings and {result.renters} renters around:")
    for campus in CAMPUSES:
        print(f"  {campus.domain}  pin at {campus.latitude}, {campus.longitude}")
    if result.photos_stored:
        print(f"Stored {result.photos_stored} photo files.")
    elif not args.no_photos:
        print("No photo files were stored (photos are not kept by this server, or the")
        print("sample pictures are missing). Listings show without pictures.")
    print("To see a deck, sign in as yourself and put your pin near one of those campuses.")
    return 0


def _photo_store(settings: Settings, engine) -> FileStore | None:
    """Where this server keeps photos, when it keeps them itself."""
    from app.services.storage import DatabaseStore, FolderStore

    if settings.storage_backend == "database":
        return DatabaseStore(engine)
    if settings.storage_backend == "local":
        return FolderStore(settings.storage_local_dir)
    return None


if __name__ == "__main__":
    raise SystemExit(main())
