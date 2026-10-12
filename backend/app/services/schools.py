"""Finding the school behind an email domain, and loading the seed list."""

import json
from pathlib import Path

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.models import School, SchoolDomain
from app.services.emails import domain_and_parents, registrable_domain

SEED_FILE = Path(__file__).resolve().parents[1] / "data" / "schools.json"


def school_for_domain(session: Session, domain: str) -> School:
    """The school for an email domain, creating a nameless one if it is new.

    `cs.washington.edu` finds the school that owns `washington.edu`. A domain
    no school owns yet is stored under its own name until someone names it.
    """
    candidates = domain_and_parents(domain)
    matches = session.scalars(select(SchoolDomain).where(SchoolDomain.domain.in_(candidates))).all()
    if matches:
        # The longest match is the most specific one.
        return max(matches, key=lambda match: len(match.domain)).school

    base = registrable_domain(domain)
    school = School(name=None)
    session.add(school)
    session.flush()
    # Two students from a new school can sign up at the same moment. The first
    # insert wins; the second finds it.
    inserted = session.execute(
        insert(SchoolDomain)
        .values(domain=base, school_id=school.id)
        .on_conflict_do_nothing(index_elements=["domain"])
        .returning(SchoolDomain.domain)
    ).first()
    if inserted is None:
        session.delete(school)
        session.flush()
    session.expire_all()
    return session.scalars(select(SchoolDomain).where(SchoolDomain.domain == base)).one().school


def seed_schools(session: Session) -> int:
    """Add or rename the schools in app/data/schools.json. Safe to run again.

    Returns how many domains were newly attached. A domain first stored
    without a name (because a student signed up before it was listed) keeps
    its school, and that school gets the name.
    """
    added = 0
    for entry in json.loads(SEED_FILE.read_text(encoding="utf-8")):
        domains = [domain.lower() for domain in entry["domains"]]
        existing = session.scalars(
            select(SchoolDomain).where(SchoolDomain.domain.in_(domains))
        ).all()
        if existing:
            school = existing[0].school
            school.name = entry["name"]
        else:
            school = School(name=entry["name"])
            session.add(school)
            session.flush()
        known = {match.domain for match in existing}
        for domain in domains:
            if domain not in known:
                session.add(SchoolDomain(domain=domain, school_id=school.id))
                added += 1
        session.flush()
    return added
