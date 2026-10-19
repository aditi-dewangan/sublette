# Build plan: phases 7 to 10

Copied from the build plan in Aditi's "Sublette: Product and Business Spec"
(Build plan tab) on 2026-10-19, so it can be read without that doc. Phases 0
to 6 are built; see `docs/build-log.md`. Where `docs/decisions.md` records a
later choice (for example, the budget being a hard limit), the decision wins.

## Rules that never change
- Only accounts with a verified .edu email can use the app. A blocklist setting can exclude a domain.
- A listing's exact address and location are returned only to its owner and to renters matched with it. Everyone else gets public_location, a fixed offset of about 150 meters.
- A renter's pin is never returned to any other user.
- No message can be sent without a match.
- Filters on both sides are applied on the server, never only in the app.
- gender_preference can be set only when space_type is private_room or shared_room.
- The app has no payments.
- Every profile, listing and message can be reported. A block hides two users from each other everywhere.
- Deleting an account removes the user's profile, listings, swipes and messages.
- Nothing in the code is specific to one school or one city. Listings are found by distance from the renter's pin, anywhere.

## Phase 7: Chat, checklist and notifications

Goal. Matched pairs can talk, track the steps to a sublet, and hear about new activity.

### Server
- Tables: messages, device_tokens.
- GET /v1/matches/{id}/messages for history and a WebSocket at /v1/ws for live messages. Only the two members of a match can read or send.
- Checklist on the match: tour done, landlord consent confirmed, dates agreed, sublease signed. PATCH /v1/matches/{id}/checklist.
- POST /v1/matches/{id}/filled: marks the listing filled and removes it from every deck and the map.
- Push through Apple Push Notification service on a new match and on a new message when the recipient is not connected.

### iPhone app
- Matches tab with a list per mode, an unread count, and the chat screen.
- Suggested first questions, the shared checklist pinned at the top, and the exact address shown once matched.
- A safety card before the first message: tour before paying, never wire money, get the landlord's consent in writing.
- Notification permission is requested at the first match, not at launch. Tapping a notification opens the right chat.

### Done when
- Messages appear on the other device within a second.
- A push arrives when the app is in the background.
- A test proves a third user gets a 403 on another pair's messages.
- A filled listing disappears from decks and the map.

## Phase 8: Trust, safety and admin

Goal. The app is safe enough for real students and meets Apple's rules for apps with user-posted content.

### Server
- Tables: reports, blocks.
- POST /v1/reports and POST /v1/blocks. A block removes each user from the other's decks, map, matches and chats.
- Scam flags sent to a review queue: payment requests or outside links in the first three messages of a chat, and the same photo used on two listings.
- Listings expire automatically after their start date unless renewed.
- Rate limits on sign-in, swipes, messages and listing creation.
- A password-protected admin page: review reports and flags, suspend a user, remove a listing.
- Terms of service and privacy policy acceptance recorded per user.

### iPhone app
- Report and block on every profile, listing and message.
- Settings: delete account, terms, privacy policy, contact us.
- A suspended account sees one screen explaining why and how to appeal.

### Done when
- A report made in the app appears in the admin queue, and a suspension takes effect on the user's next request.
- A test proves a blocked pair cannot see or message each other.
- Reporting, blocking, moderation and in-app account deletion all work, since App Store review checks for them.

## Phase 9: UI/UX polish, beta and release

Goal. The app looks and feels like Sublette, survives real use, and is live on the App Store.

### Design and experience
- Finish the design system: colors, type, buttons, cards, chips, the pin shape as the logo mark.
- Mode color throughout: yellow in Renter mode, orange in Lister mode, magenta for the like action and for matches.
- The match moment: a full-screen yellow to orange to magenta gradient with both profiles and a haptic.
- Empty, loading and error states for every screen. Onboarding copy in the brand voice.
- Accessibility: Dynamic Type, VoiceOver labels, and no white text on yellow or orange.
- Dark mode.

### Offline
- Cache the next 20 deck cards, saved and matched listings, and chat history in SwiftData.
- Queue swipes and messages made offline and send them when the connection returns.

### Release
- Analytics events for the funnel: sign-up, profile complete, first swipe, first match, filled. Also record days from publishing a listing to its first match and to filled, likes that get no response, and use of each feature. The business model is decided from these. Referral codes: each user has a code, the server records which code a new lister used, and an admin page lists listings that have passed the 7-day check so rewards can be paid. Crash reporting.
- App icon, launch screen, App Store screenshots and privacy labels. A share card for each listing: an image and link sized for posting in housing groups. Store title: "Sublette: College Sublets."
- TestFlight beta with 20 to 50 UW students for two weeks. Fix what they hit.
- Submit for App Store review.

### Done when
- Beta testers get from download to a match with no help.
- Crash-free sessions are above 99% across the beta.
- The app is approved and downloadable.

## Phase 10: AI recommender

Goal. A renter can describe what they want in plain words and get a short list with reasons. Built last, once there are real listings to recommend from.

### Server
- POST /v1/assistant/query takes the renter's message. It runs in three steps:
- Understand. The language model turns the message into structured preference changes, returned as JSON that matches the renter_profiles fields.
- Retrieve. The normal matching engine from phase 4 returns up to 20 eligible listings. The model plays no part in eligibility.
- Rank and explain. The model receives those listings and returns an ordered list of listing ids with one or two sentences each.
- The server discards any id that was not in the list it sent. The model can never add a listing, a price or a fact.
- The model receives listing attributes and public_location only. It never receives exact addresses, names, emails or chat messages.
- A per-user rate limit, a setting that turns the feature off, and logging of queries for review.
- An evaluation set of 30 sample requests with the preferences each should produce.

### iPhone app
- An Assistant screen in Renter mode: a text box, results as the normal listing cards with the model's reasons, and a button to save the understood preferences to the profile.
- A label stating that suggestions are generated automatically and drawn only from listings on Sublette.

### Done when
- A test proves a made-up listing id from the model never reaches the app.
- The evaluation set produces the expected preferences in at least 27 of 30 cases.
- Turning the setting off hides the screen without an app update.

### After the build
- Revenue features are not in this plan. The first revenue test is chosen once 50 sublets have been marked filled, and whatever we choose becomes its own phase. In phase 7, both sides confirm "Filled" and each gets a completed-sublet mark on their profile, so that count can be trusted.
