"""The terms of service and privacy policy, as plain web pages.

The app links to them from sign-up and Settings. They are served by this
server so they cost nothing to host and always match the version the API
asks students to accept (SUBLETTE_TERMS_VERSION).
"""

from html import escape

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

from app.deps import AppSettings

router = APIRouter(tags=["pages"])

STYLE = """
body { font: 17px/1.5 -apple-system, system-ui, sans-serif; color: #2A1422;
       background: #FFF8EC; max-width: 40rem; margin: 0 auto; padding: 1.5rem 1rem 4rem; }
h1 { font-size: 1.6rem; } h2 { font-size: 1.15rem; margin-top: 2rem; }
a { color: #D6177A; } .note { opacity: .75; font-size: .9rem; }
"""


def page(title: str, version: str, body: str) -> HTMLResponse:
    return HTMLResponse(
        "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        f"<title>{escape(title)} · Sublette</title><style>{STYLE}</style></head><body>"
        f"<h1>{escape(title)}</h1><p class='note'>Version {escape(version)}</p>{body}"
        "</body></html>"
    )


@router.get("/terms", response_class=HTMLResponse)
def terms(settings: AppSettings) -> HTMLResponse:
    email = escape(settings.support_email)
    return page(
        "Terms of service",
        settings.terms_version,
        f"""
<p>Sublette helps college students find people to take over, or hand over, a
room for a while. By using Sublette you agree to these terms.</p>

<h2>Who can use Sublette</h2>
<p>You need a school email address (ending in .edu) that you can receive mail
at, and you must be at least 18. One account per person. Keep your sign-in
codes to yourself.</p>

<h2>What you post</h2>
<p>Your profile, listings and messages must be true and your own. Only list a
place you have the right to sublet; you're responsible for getting your
landlord's consent and for following your lease and local law. No
discrimination, harassment, threats, spam, scams, or anything illegal.
Photos must be of the actual place.</p>

<h2>Sublette is not a party to your sublet</h2>
<p>Sublette has no payments. Rent, deposits and the sublease are agreed
directly between you and the other student. We don't inspect places, check
leases, or guarantee anyone. Tour the place before you pay anything, never
wire money or pay with gift cards, and get your landlord's consent in
writing.</p>

<h2>Reports, blocks and removal</h2>
<p>You can report any profile, listing or message, and block anyone. We
review reports and may remove content or suspend accounts that break these
terms. If your account is suspended you can appeal by writing to
<a href="mailto:{email}">{email}</a> from your school address.</p>

<h2>Deleting your account</h2>
<p>You can delete your account at any time in Settings. That removes your
profile, listings, swipes and messages.</p>

<h2>The service</h2>
<p>Sublette is provided as is. We may change or stop the service, and may
update these terms; when they change, the app asks you to accept the new
version. Questions: <a href="mailto:{email}">{email}</a>.</p>
""",
    )


@router.get("/privacy", response_class=HTMLResponse)
def privacy(settings: AppSettings) -> HTMLResponse:
    email = escape(settings.support_email)
    return page(
        "Privacy policy",
        settings.terms_version,
        f"""
<p>This is what Sublette keeps about you, who sees it, and how to remove it.</p>

<h2>What we keep</h2>
<ul>
<li>Your school email address, to sign you in and confirm you're a student.</li>
<li>Your profile: first name, year, program, an optional bio, photo and
gender, and whether you smoke or have pets.</li>
<li>As a renter: your dates, budget, preferences and the map pin you choose.</li>
<li>As a lister: your listings, their address and photos.</li>
<li>Your likes, passes, matches and chat messages, and reports you make.</li>
<li>A push notification token for your phone, if you allow notifications.</li>
</ul>

<h2>Who sees what</h2>
<ul>
<li>Other students see your first name, photo, school, year and program, and
your listings without their exact address.</li>
<li>A listing's exact address goes only to renters who matched with it.</li>
<li>Your map pin is never shown to anyone else.</li>
<li>Messages are seen only by the two people in the chat, and by our
reviewers when a message is reported or flagged as a possible scam.</li>
</ul>

<h2>What we don't do</h2>
<p>We don't sell your information or show ads. We don't track you across
other apps or websites.</p>

<h2>Services we use</h2>
<p>Our server host and database store the data above. An email provider sends
your sign-in codes. Apple delivers push notifications.</p>

<h2>Deleting your data</h2>
<p>Delete your account in Settings and your profile, listings, swipes,
matches and messages are removed. Reports you made are kept without your
name so reviews can finish.</p>

<h2>Contact</h2>
<p><a href="mailto:{email}">{email}</a></p>
""",
    )
