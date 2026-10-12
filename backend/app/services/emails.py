"""Rules about email addresses: what is valid, what counts as .edu, what is blocked."""

import re

from app.errors import ApiError
from app.schemas.errors import FieldError

_EMAIL = re.compile(
    r"^[a-z0-9._%+'-]{1,64}"
    r"@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$"
)


def normalize_email(raw: str) -> str:
    """Trim and lowercase an address, or raise if it is not an address at all."""
    email = raw.strip().lower()
    if len(email) > 254 or not _EMAIL.match(email) or ".." in email:
        raise ApiError(
            422,
            "invalid_email",
            "That doesn't look like an email address.",
            fields=[FieldError(field="email", message="Enter your school email address.")],
        )
    return email


def domain_of(email: str) -> str:
    return email.rsplit("@", 1)[1]


def is_edu(domain: str) -> bool:
    """True for `uw.edu` and `cs.washington.edu`; false for `edu.au` and `gmail.com`."""
    return domain.endswith(".edu")


def registrable_domain(domain: str) -> str:
    """The school's own domain: `cs.washington.edu` becomes `washington.edu`."""
    return ".".join(domain.split(".")[-2:])


def domain_and_parents(domain: str) -> list[str]:
    """`a.b.uw.edu` becomes [`a.b.uw.edu`, `b.uw.edu`, `uw.edu`], most specific first."""
    labels = domain.split(".")
    return [".".join(labels[start:]) for start in range(len(labels) - 1)]


def is_blocked(domain: str, blocked: frozenset[str]) -> bool:
    """A blocked domain also blocks its subdomains."""
    return any(candidate in blocked for candidate in domain_and_parents(domain))


def require_school_email(raw: str, blocked: frozenset[str]) -> str:
    """The address, normalized, if it may be used to sign in. Raises otherwise."""
    email = normalize_email(raw)
    domain = domain_of(email)
    if not is_edu(domain):
        raise ApiError(
            422,
            "not_edu_email",
            "Sublette is for students. Use your school email ending in .edu.",
            fields=[FieldError(field="email", message="Use an email address ending in .edu.")],
        )
    if is_blocked(domain, blocked):
        raise ApiError(
            403,
            "domain_blocked",
            "Sign-ups from that email domain aren't open. Use a different school email.",
            fields=[FieldError(field="email", message="This email domain can't be used.")],
        )
    return email
