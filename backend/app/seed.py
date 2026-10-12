"""Load reference data. Run with: python -m app.seed  (also run by `make migrate`)."""

from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import make_engine
from app.services.schools import seed_schools


def main() -> None:
    engine = make_engine(get_settings())
    with Session(engine) as session:
        added = seed_schools(session)
        session.commit()
    engine.dispose()
    print(f"Schools seeded ({added} new domain(s)).")


if __name__ == "__main__":
    main()
