"""The admin page at /admin: review reports and scam flags, suspend people,
remove listings.

Protected by a password (SUBLETTE_ADMIN_PASSWORD, user name "admin") sent
the browser's own way (HTTP Basic). Without the setting the page doesn't
exist. Wrong passwords are limited per address, and every form carries a
token so another website can't submit one on your behalf.

Plain HTML from the server: nothing to build or host separately.
"""

import hashlib
import hmac
import logging
import secrets
import uuid
from base64 import b64decode
from datetime import timedelta
from html import escape
from typing import Annotated
from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy import func, select, update

from app.deps import AppSettings, ClientIp, DbSession, Live, Now, Storage
from app.errors import ApiError
from app.models import Listing, Message, Report, User
from app.services import rate_limit

logger = logging.getLogger("sublette.admin")

router = APIRouter(prefix="/admin", include_in_schema=False)

USER_NAME = "admin"
FAILURES_PER_HOUR = 20
HOUR = timedelta(hours=1)

REASONS = {
    "scam": "Scam or asking for money",
    "harassment": "Harassment",
    "inappropriate": "Inappropriate",
    "fake": "Fake or misleading",
    "discrimination": "Discrimination",
    "unsafe": "Unsafe",
    "other": "Other",
    "payment_request": "Payment request early in a chat",
    "outside_link": "Outside link early in a chat",
    "duplicate_photo": "Photo also on another person's listing",
}


def form_token(settings) -> str:
    """Put in every form. Unknown to other websites, so they can't post forms here."""
    key = f"{settings.secret_key}\n{settings.admin_password}".encode()
    return hmac.new(key, b"sublette-admin-form", hashlib.sha256).hexdigest()


def require_admin(
    request: Request, session: DbSession, settings: AppSettings, ip: ClientIp, now: Now
):
    if not settings.admin_password:
        raise ApiError(404, "not_found", "Not Found")
    bucket = f"admin:ip:{ip}"
    if rate_limit.count(session, bucket, window=HOUR, now=now) >= FAILURES_PER_HOUR:
        raise ApiError(429, "rate_limited", "Too many wrong passwords. Wait an hour.")
    scheme, _, encoded = request.headers.get("authorization", "").partition(" ")
    try:
        name, _, password = b64decode(encoded).decode().partition(":")
    except (ValueError, UnicodeDecodeError):
        name = password = ""
    good = secrets.compare_digest(name.encode(), USER_NAME.encode()) & secrets.compare_digest(
        password.encode(), settings.admin_password.encode()
    )
    if scheme.lower() != "basic" or not good:
        if encoded:
            rate_limit.hit(session, bucket, limit=FAILURES_PER_HOUR + 1, window=HOUR, now=now)
            session.commit()
            logger.warning("Wrong admin password from %s", ip)
        raise ApiError(
            401,
            "admin_sign_in",
            "Sign in as admin.",
            headers={"WWW-Authenticate": 'Basic realm="Sublette admin", charset="UTF-8"'},
        )


Admin = Annotated[None, Depends(require_admin)]


STYLE = """
body { font: 15px/1.45 -apple-system, system-ui, sans-serif; color: #2A1422;
       background: #FFF8EC; margin: 0 auto; max-width: 70rem; padding: 1rem; }
a { color: #D6177A; } h1 { font-size: 1.4rem; } h2 { font-size: 1.1rem; margin-top: 1.6rem; }
.card { background: #fff; border-radius: 10px; padding: .8rem 1rem; margin: .7rem 0; }
.meta { opacity: .7; font-size: .85rem; } .tag { font-weight: 600; }
.excerpt { white-space: pre-wrap; background: #FFF8EC; padding: .5rem; border-radius: 6px; }
form.inline { display: inline-block; margin: .3rem .4rem 0 0; }
input[type=text] { padding: .3rem; width: 16rem; max-width: 100%; }
button { padding: .3rem .7rem; border-radius: 6px; border: 1px solid #2A1422; background: #fff; }
button.danger { border-color: #D6177A; color: #D6177A; }
nav a { margin-right: 1rem; } img { height: 90px; border-radius: 6px; margin-right: 4px; }
"""


def page(title: str, body: str) -> HTMLResponse:
    return HTMLResponse(
        "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<meta name='robots' content='noindex'>"
        f"<title>{escape(title)} · Sublette admin</title><style>{STYLE}</style></head><body>"
        "<nav><a href='/admin'>Open reports</a><a href='/admin?status=closed'>Closed</a>"
        "<form class='inline' action='/admin/find'><input type='text' name='q' "
        "placeholder='Find a person by email'> <button>Find</button></form></nav>"
        f"<h1>{escape(title)}</h1>{body}</body></html>",
        headers={"Cache-Control": "no-store"},
    )


def button(settings, action: str, label: str, reason: bool = False, danger: bool = False) -> str:
    field = (
        "<input type='text' name='reason' required maxlength='300' placeholder='Reason "
        "(the person sees it)'> "
        if reason
        else ""
    )
    return (
        f"<form class='inline' method='post' action='{escape(action)}'>"
        f"<input type='hidden' name='token' value='{form_token(settings)}'>{field}"
        f"<button class='{'danger' if danger else ''}'>{escape(label)}</button></form>"
    )


def person_link(user: User | None) -> str:
    if user is None:
        return "<span class='meta'>(account deleted)</span>"
    name = escape(user.first_name or "No name")
    status = " <span class='tag'>SUSPENDED</span>" if user.status != "active" else ""
    return f"<a href='/admin/users/{user.id}'>{name} &lt;{escape(user.email)}&gt;</a>{status}"


def when(value) -> str:
    return value.strftime("%Y-%m-%d %H:%M UTC") if value else ""


def report_card(settings, item: Report) -> str:
    target = {
        "user": "Profile",
        "listing": f"Listing <a href='/admin/listings/{item.listing_id}'>{item.listing_id}</a>",
        "message": "Message"
        + (
            f" in a chat about <a href='/admin/listings/{item.listing_id}'>a listing</a>"
            if item.listing_id
            else ""
        ),
    }[item.target]
    by = (
        "Flagged by Sublette"
        if item.source == "automatic"
        else "Reported by " + person_link(item.reporter)
    )
    parts = [
        f"<div class='card'><span class='tag'>{escape(REASONS.get(item.reason, item.reason))}"
        f"</span> · {target}<div class='meta'>{when(item.created_at)} · {by}</div>",
        f"<div>About: {person_link(item.subject)}</div>",
    ]
    if item.details:
        parts.append(f"<div>Details: {escape(item.details)}</div>")
    if item.excerpt:
        parts.append(f"<div class='excerpt'>{escape(item.excerpt)}</div>")
    if item.status == "open":
        parts.append(button(settings, f"/admin/reports/{item.id}/dismiss", "Dismiss (no problem)"))
        parts.append(button(settings, f"/admin/reports/{item.id}/actioned", "Mark handled"))
        if item.subject and item.subject.status == "active":
            parts.append(
                button(
                    settings,
                    f"/admin/users/{item.subject_id}/suspend",
                    "Suspend this person",
                    reason=True,
                    danger=True,
                )
            )
        if item.target == "listing" and item.listing_id:
            parts.append(
                button(
                    settings,
                    f"/admin/listings/{item.listing_id}/remove",
                    "Remove listing",
                    reason=True,
                    danger=True,
                )
            )
    else:
        parts.append(
            f"<div class='meta'>{escape(item.status)} {when(item.resolved_at)}"
            f"{' · ' + escape(item.resolution) if item.resolution else ''}</div>"
        )
    parts.append("</div>")
    return "".join(parts)


@router.get("", response_class=HTMLResponse)
def queue(_: Admin, session: DbSession, settings: AppSettings, status: str = "open"):
    query = select(Report)
    if status == "open":
        query = query.where(Report.status == "open").order_by(Report.created_at)
        title = "Open reports"
    else:
        query = query.where(Report.status != "open").order_by(Report.resolved_at.desc())
        title = "Closed reports"
    items = session.scalars(query.limit(200)).unique().all()
    total = session.scalar(select(func.count()).where(Report.status == "open"))
    body = f"<p class='meta'>{total} open. Oldest first.</p>" if status == "open" else ""
    body += "".join(report_card(settings, item) for item in items) or "<p>Nothing here.</p>"
    return page(title, body)


@router.get("/find", response_class=HTMLResponse)
def find(_: Admin, session: DbSession, q: str = ""):
    text = q.strip().lower()
    users = (
        session.scalars(select(User).where(User.email.contains(text)).limit(50)).unique().all()
        if text
        else []
    )
    if len(users) == 1:
        return RedirectResponse(f"/admin/users/{users[0].id}", status_code=303)
    rows = "".join(f"<div class='card'>{person_link(user)}</div>" for user in users)
    return page(f"People matching “{q}”", rows or "<p>Nobody.</p>")


@router.get("/users/{user_id}", response_class=HTMLResponse)
def person(user_id: uuid.UUID, _: Admin, session: DbSession, settings: AppSettings):
    user = session.get(User, user_id)
    if user is None:
        return page("Not found", "<p>That account was deleted.</p>")
    body = [
        f"<div class='card'>{person_link(user)}<div class='meta'>{escape(user.school.display_name)}"
        f" · joined {when(user.created_at)} · {user.completed_sublets} completed sublets</div>"
    ]
    if user.status != "active":
        body.append(
            f"<p>Suspended {when(user.suspended_at)}: {escape(user.suspended_reason or '')}</p>"
        )
        body.append(button(settings, f"/admin/users/{user.id}/unsuspend", "Lift the suspension"))
    else:
        body.append(
            button(settings, f"/admin/users/{user.id}/suspend", "Suspend", reason=True, danger=True)
        )
    body.append("</div><h2>Listings</h2>")
    listings = session.scalars(
        select(Listing).where(Listing.owner_id == user.id).order_by(Listing.created_at.desc())
    ).unique()
    body += [
        f"<div class='card'><a href='/admin/listings/{item.id}'>{escape(item.address or 'Draft')}"
        f"</a> · {escape(item.status)}</div>"
        for item in listings
    ] or ["<p class='meta'>None.</p>"]
    body.append("<h2>Reports about them</h2>")
    about = session.scalars(
        select(Report).where(Report.subject_id == user.id).order_by(Report.created_at.desc())
    ).unique()
    body += [report_card(settings, item) for item in about] or ["<p class='meta'>None.</p>"]
    made = session.scalar(select(func.count()).where(Report.reporter_id == user.id))
    sent = session.scalar(select(func.count()).where(Message.sender_id == user.id))
    body.append(f"<p class='meta'>They made {made} reports and sent {sent} messages.</p>")
    return page(user.first_name or user.email, "".join(body))


@router.get("/listings/{listing_id}", response_class=HTMLResponse)
def listing_page(
    listing_id: uuid.UUID, _: Admin, session: DbSession, settings: AppSettings, storage: Storage
):
    listing = session.get(Listing, listing_id)
    if listing is None:
        return page("Not found", "<p>That listing was deleted.</p>")
    photos = "".join(
        f"<a href='{escape(url)}'><img src='{escape(url)}' alt=''></a>"
        for url in (storage.public_url(photo.key) for photo in listing.photos)
        if url
    )
    rent = f"${listing.rent_cents / 100:,.0f}/month" if listing.rent_cents else "no rent yet"
    body = [
        f"<div class='card'><div>{photos}</div><p>{escape(listing.address or '')}</p>"
        f"<p>{escape(listing.status)} · {rent} · {listing.start_date} to {listing.end_date}"
        f" · landlord consent: {listing.landlord_consent}</p>"
        f"<p>{escape(listing.housemates_note or '')}</p>"
        f"<p>Lister: {person_link(listing.owner)}</p>"
    ]
    if listing.status == "removed":
        body.append(f"<p>Removed: {escape(listing.removed_reason or '')}</p>")
    else:
        body.append(
            button(
                settings, f"/admin/listings/{listing.id}/remove", "Remove", reason=True, danger=True
            )
        )
    body.append("</div><h2>Reports</h2>")
    reports = session.scalars(
        select(Report).where(Report.listing_id == listing.id).order_by(Report.created_at.desc())
    ).unique()
    body += [report_card(settings, item) for item in reports] or ["<p class='meta'>None.</p>"]
    return page("Listing", "".join(body))


MAX_FORM_BYTES = 4096


async def read_form(request: Request) -> dict[str, str]:
    """The admin page's small forms, read without an extra package."""
    body = await request.body()
    if len(body) > MAX_FORM_BYTES:
        raise ApiError(413, "form_too_large", "That form is too large.")
    fields = parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True)
    return {name: values[0] for name, values in fields.items()}


Fields = Annotated[dict[str, str], Depends(read_form)]


def checked(settings, fields: dict[str, str], reason: bool = False) -> str:
    """Checks the form's token and returns its reason, if it needs one."""
    if not secrets.compare_digest(fields.get("token", ""), form_token(settings)):
        raise ApiError(403, "form_expired", "Reload the page and try again.")
    text = " ".join(fields.get("reason", "").split())
    if reason and not 1 <= len(text) <= 300:
        raise ApiError(422, "reason_required", "Give a reason of up to 300 characters.")
    return text


def _back(request: Request) -> RedirectResponse:
    referer = request.headers.get("referer", "")
    target = referer if "/admin" in referer else "/admin"
    return RedirectResponse(target, status_code=303)


def _close(session, condition, status: str, resolution: str, now) -> None:
    session.execute(
        update(Report)
        .where(condition, Report.status == "open")
        .values(status=status, resolution=resolution, resolved_at=now)
    )


@router.post("/reports/{report_id}/{verdict}")
def close_report(
    report_id: uuid.UUID,
    verdict: str,
    request: Request,
    fields: Fields,
    _: Admin,
    session: DbSession,
    settings: AppSettings,
    now: Now,
):
    checked(settings, fields)
    if verdict not in ("dismiss", "actioned"):
        raise ApiError(404, "not_found", "Not Found")
    status = "dismissed" if verdict == "dismiss" else "actioned"
    _close(session, Report.id == report_id, status, "", now)
    session.commit()
    return _back(request)


@router.post("/users/{user_id}/suspend")
def suspend(
    user_id: uuid.UUID,
    request: Request,
    fields: Fields,
    _: Admin,
    session: DbSession,
    settings: AppSettings,
    live: Live,
    now: Now,
):
    """Takes effect on the person's next request, and closes their live
    connection at once."""
    reason = checked(settings, fields, reason=True)
    user = session.get(User, user_id)
    if user is None:
        raise ApiError(404, "not_found", "Not Found")
    user.status = "suspended"
    user.suspended_reason = reason
    user.suspended_at = now
    _close(session, Report.subject_id == user.id, "actioned", f"Suspended: {reason}", now)
    session.commit()
    live.suspend(user.id)
    logger.info("Suspended %s", user.id)
    return _back(request)


@router.post("/users/{user_id}/unsuspend")
def unsuspend(
    user_id: uuid.UUID,
    request: Request,
    fields: Fields,
    _: Admin,
    session: DbSession,
    settings: AppSettings,
):
    checked(settings, fields)
    user = session.get(User, user_id)
    if user is None:
        raise ApiError(404, "not_found", "Not Found")
    user.status = "active"
    user.suspended_reason = None
    user.suspended_at = None
    session.commit()
    return _back(request)


@router.post("/listings/{listing_id}/remove")
def remove_listing(
    listing_id: uuid.UUID,
    request: Request,
    fields: Fields,
    _: Admin,
    session: DbSession,
    settings: AppSettings,
    now: Now,
):
    """The listing leaves every deck and the map at once; its owner sees why."""
    reason = checked(settings, fields, reason=True)
    listing = session.get(Listing, listing_id)
    if listing is None:
        raise ApiError(404, "not_found", "Not Found")
    listing.status = "removed"
    listing.removed_reason = reason
    # Reports about the listing itself; reports on messages in its chats stay
    # open, since they are about a person.
    _close(
        session,
        (Report.listing_id == listing.id) & (Report.target == "listing"),
        "actioned",
        f"Listing removed: {reason}",
        now,
    )
    session.commit()
    return _back(request)
