"""Telling people about new activity.

Every change goes as a live event to each phone with the app open (see
services/live.py). A push notification goes too when:
* a match is made: to the renter, whose phone didn't make it;
* a message arrives and the recipient has no phone connected;
* a new listing fits a renter who tapped "Notify me" (services/alerts.py
  decides how often).

Events carry the match as the recipient sees it, so the app can update the
Matches list, the unread count and an open chat from the event alone.
"""

import uuid
from datetime import datetime

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models import Listing, Match, Message, RenterProfile, Swipe, User
from app.services.alerts import raise_alert
from app.services.chat import activity_for, message_out, other_side
from app.services.live import LiveHub
from app.services.matching import Renter, failures, summary
from app.services.push import PushDispatcher, PushNote, preview
from app.services.safety import blocked_with
from app.services.storage import PhotoStorage
from app.services.swipes import match_out


def _match_json(session: Session, match: Match, viewer: User, storage: PhotoStorage) -> dict:
    activity = activity_for(session, viewer, [match.id])[match.id]
    return match_out(match, viewer, storage, activity).model_dump(mode="json")


def _people(match: Match) -> tuple[User, User]:
    return match.renter, match.lister


def announce_message(
    session: Session,
    live: LiveHub,
    push: PushDispatcher,
    storage: PhotoStorage,
    match: Match,
    message: Message,
) -> None:
    """After a message is stored: to both people's open apps (the sender's
    other phones too), and a push to the recipient if no app is open."""
    for person in _people(match):
        live.publish(
            person.id,
            {
                "type": "message",
                "message": message_out(message, person.id).model_dump(mode="json"),
                "match": _match_json(session, match, person, storage),
            },
        )
    sender = match.renter if message.sender_id == match.renter_id else match.lister
    recipient_id = other_side(match, sender)
    if live.is_connected(recipient_id):
        return
    note = PushNote(
        title=sender.first_name or "New message",
        body=preview(message.body),
        data={
            "kind": "message",
            "match_id": str(match.id),
            "role": "renter" if recipient_id == match.renter_id else "lister",
        },
    )
    push.run(lambda job_session: push.deliver(job_session, recipient_id, note))


def announce_match(
    session: Session, live: LiveHub, push: PushDispatcher, storage: PhotoStorage, match: Match
) -> None:
    """After the lister's like made a match. The renter hears about it."""
    for person in _people(match):
        live.publish(
            person.id,
            {
                "type": "match",
                "new_match": person.id == match.renter_id,
                "match": _match_json(session, match, person, storage),
            },
        )
    lister_name = match.lister.first_name or "A lister"
    note = PushNote(
        title="It's a match!",
        body=f"{lister_name} liked you back. Say hi and set up a tour.",
        data={"kind": "match", "match_id": str(match.id), "role": "renter"},
    )
    renter_id = match.renter_id
    push.run(lambda job_session: push.deliver(job_session, renter_id, note))


def announce_match_change(
    session: Session, live: LiveHub, storage: PhotoStorage, match: Match
) -> None:
    """The checklist or "Filled" changed: both open apps update."""
    for person in _people(match):
        live.publish(
            person.id,
            {
                "type": "match",
                "new_match": False,
                "match": _match_json(session, match, person, storage),
            },
        )


def alert_new_listing(push: PushDispatcher, listing_id: uuid.UUID, now: datetime) -> None:
    """After a listing is first published: an alert for each renter who asked
    to hear about new places, if it fits their search. Sent as each renter
    chose (services/alerts.py). Runs in the background."""

    def job(session: Session) -> None:
        listing = session.get(Listing, listing_id)
        if listing is None or listing.status != "active" or listing.public_latitude is None:
            return
        point = func.geography(
            func.ST_SetSRID(
                func.ST_MakePoint(listing.public_longitude, listing.public_latitude), 4326
            )
        )
        pin = func.geography(
            func.ST_SetSRID(
                func.ST_MakePoint(RenterProfile.pin_longitude, RenterProfile.pin_latitude), 4326
            )
        )
        swiped = select(Swipe.renter_id).where(
            Swipe.side == "renter", Swipe.listing_id == listing.id
        )
        rows = session.execute(
            select(User, RenterProfile)
            .join(RenterProfile, RenterProfile.user_id == User.id)
            .where(
                RenterProfile.notify_new_listings.is_(True),
                RenterProfile.pin_latitude.is_not(None),
                func.ST_DWithin(pin, point, RenterProfile.radius_m),
                User.id != listing.owner_id,
                User.status == "active",
                User.alert_frequency != "off",
                User.id.not_in(swiped),
                User.id.not_in(blocked_with(listing.owner_id)),
            )
        ).all()

        from app.routers.renter_profile import is_complete

        for user, profile in rows:
            if not user.profile_complete or not is_complete(profile):
                continue
            renter = Renter.from_models(user, profile)
            if failures(renter, listing, listing.owner.school_id):
                continue
            raise_alert(session, push, user, "new_listing", listing, summary(renter, listing), now)

    push.run(job)
