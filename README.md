# Sublette

An iPhone app that matches college students who need a short-term place with
students who need someone to take over their lease. Any `.edu` email can join.

- `ios/` is the iPhone app: Swift and SwiftUI, iOS 17 or later.
- `backend/` is the server: Python 3.12, FastAPI, PostgreSQL 16 with PostGIS.
- `docs/` holds the contracts both codebases are tested against, the rename log and decisions.

## Build status

| Phase | What it delivers | Status |
| --- | --- | --- |
| 0 | Scaffolding: both codebases run and talk to each other | Done |
| 1 | Accounts and .edu email verification | Done |
| 2 | Lister mode: create and manage a listing | Done |
| 3 | Renter mode: preferences, map pin, and the mode toggle | Done |
| 4 | Matching engine: who sees which listing, scored and explained | Done |
| 5 | Swipe decks and matches | Done |
| 6 | Map and pins | Done |
| 7 | Chat, checklist and notifications | Done |
| 8 | Trust, safety and admin | Built on `phase-8`; see its pull request |
| 9 and 10 | Polish and release, then the AI recommender | Not started |

## Set up (once)

You need a Mac with:

| Tool | Why | Install |
| --- | --- | --- |
| Xcode (current version) | Builds the iPhone app | Mac App Store |
| Docker Desktop | Runs the local database | docker.com |
| Python 3.12 | Runs the server | `brew install python@3.12` |
| XcodeGen | Generates the Xcode project | `brew install xcodegen` |

Then, from the repository root:

```sh
make setup
```

## Run it

Start the database and the server with one command:

```sh
make dev
```

The server is now at http://localhost:8000. Check it:

```sh
curl http://localhost:8000/health
# {"status":"ok","version":"0.2.0","environment":"local","database":{"reachable":true,"postgis":"3.4.2"}}
```

Interactive API docs are at http://localhost:8000/docs.

In a second terminal, open the iPhone app:

```sh
make ios
```

Pick an iPhone simulator and press Run.

### Sign up on your own machine

By default no email is sent in development. The code is printed in the
terminal where `make dev` is running (to get real emails instead, see
"Codes by email in development" below):

1. In the app, enter any address ending in `.edu` (it does not have to exist) and tap **Send code**.
2. In the `make dev` terminal, find the line `Sign-in code for you@school.edu: 123456`.
3. Type that code into the app, fill in the profile, and pick a starting mode.

Close and reopen the app and you are still signed in. Photos you add are kept
in `backend/.dev-storage/`. To start over, use **Delete account** on the
Profile tab, or `make db-reset` to wipe every account.

Run `make` with no arguments to list every command.

### Codes by email in development

To get codes by email while testing, with every one filed in a DEV label in the
app's Gmail (`subletteofficial@gmail.com`):

1. Set up Brevo as in "Staging, for $0" step 3, with `subletteofficial@gmail.com` as the verified sender.
2. Create `backend/.env` with:
   ```sh
   SUBLETTE_EMAIL_BACKEND=brevo
   SUBLETTE_BREVO_API_KEY=xkeysib-your-key
   SUBLETTE_EMAIL_FROM=Sublette <subletteofficial@gmail.com>
   SUBLETTE_EMAIL_REDIRECT_TO=subletteofficial+dev@gmail.com
   ```
3. In Gmail, create a filter for mail to `subletteofficial+dev@gmail.com`: skip the inbox, apply the label `DEV`, never send it to spam.
4. Restart `make dev`.

Every code now goes to the DEV label, whatever `.edu` address was typed, with
that address in the subject: `[LOCAL] 482913 is your Sublette code (for you@uw.edu)`.
Made-up test addresses email nobody. Production refuses to start with a
redirect set, so students' codes can never be copied to one inbox.

To email each code to the address that was typed instead, leave
`SUBLETTE_EMAIL_REDIRECT_TO` out of `backend/.env`.

**The code is also printed in the terminal running `make dev`,** whatever the
email does:

```
WARNING:sublette.auth:Sign-in code for you@uw.edu: 482913  (also emailed)
```

If the email fails (a wrong Brevo key, a spam filter, Brevo's daily limit),
the terminal says so and the printed code still signs you in. This is on by
default only for a server running on your own machine; set
`SUBLETTE_EMAIL_ECHO_CODES=false` to turn it off. Production refuses to start
with it on.

### Fake listings to try the deck

```sh
make seed-fake   # 1,000 listings and 200 renters around three campuses
```

The campuses are UW in Seattle, UT Austin and Boston University, picked from
the school list by domain. Every fake account's email starts with `seed-`, so
running it again replaces the batch and real accounts are never touched.
`make seed-fake ARGS=--remove` takes it all out. Put your own search pin near
one of those campuses, then try `GET /v1/deck/listings` at
http://localhost:8000/docs.

### Chat between two simulators

You need two accounts, one on each side, and both apps open:

1. `make dev` in one Terminal window (from the `sublette` folder).
2. In Xcode, pick an iPhone simulator and press Run. Sign up as a renter
   (any made-up `.edu` address; the code is printed in the `make dev` window)
   and like a listing.
3. In Xcode, pick a *different* iPhone simulator (Product > Destination) and
   press Run again. Both simulators stay open. Sign up as the lister who owns
   that listing, open Renters, and like the renter back. That's a match.
4. Tap "Send a message". Messages show on the other simulator within a second.
   The checklist ticks on both. "Mark filled" takes the listing out of every
   deck and off the map.

Notifications: allow them when asked (at the first match), then press the
Home button (Device > Home, or Shift-Command-H) on one simulator and send a
message from the other. A local server pushes straight into the simulator with
Xcode's `xcrun simctl push`, so this needs no Apple account. Every push is
also printed in the `make dev` window. Real iPhones need Apple Push
Notification service: see "Push notifications on a real iPhone" below.

## Test it

```sh
make check      # server: lint, format, rename log, tests (needs `make db`)
make ios-test   # iPhone app: build and unit tests in a simulator
```

Both also run on GitHub on every push (`.github/workflows/ci.yml`).

## Two habits this repository enforces

**1. When you add a dependency, test what happens when it is unavailable.**

Each dependency has tests for the day it is down. So far:

| Dependency | What happens when it is down | Where it is tested |
| --- | --- | --- |
| Database (server) | The server still starts. `/health` answers 503 in milliseconds with a clear message and no connection details. Other routes still answer. It recovers without a restart. | `backend/tests/test_health.py` |
| Server (iPhone app) | The app still launches, the tabs and the mode switch still work, and the status card says the server can't be reached and how to fix it. | `ios/SubletteTests/APIClientTests.swift`, `ServerStatusModelTests.swift` |
| Info.plist settings (iPhone app) | A missing or malformed server address falls back to the local server. | `ios/SubletteTests/AppConfigurationTests.swift` |
| Database (any `/v1` request) | 503 `service_unavailable` with "try again in a minute", never a bare 500. | `backend/tests/test_health.py` |
| Email provider, on your own machine | The code is printed in the `make dev` terminal as well as emailed; if the email fails, the terminal says why and the printed code still works. | `backend/tests/test_echo_codes.py` |
| Email provider (server, SMTP or Brevo) | Requesting a code answers 503 `email_unavailable`. A wrong key, an unverified sender, Brevo's daily limit or a slow answer (over 10 seconds) all count as unavailable, and the reason goes to the server log without the key. No code is stored and the failed try does not count against the student's limit. Signed-in students are unaffected. Sign-up works again as soon as the provider is back. | `backend/tests/test_auth.py`, `test_brevo.py` |
| Photo storage (server) | Asking for an upload link answers 503 `uploads_unavailable`. Sign-up, the profile, listing drafts and account deletion all still work without photos. With photos in the database, a database outage answers 503 instead of a broken image. | `backend/tests/test_uploads.py`, `test_storage_database.py`, `test_listings.py` |
| Apple's address lookup (iPhone app) | "Couldn't look up the address" with a retry; the rest of the listing is kept. | `ios/SubletteTests/ListingEditorModelTests.swift` |
| Server (iPhone app, signed in) | Reopening the app offline shows the saved profile and keeps the student signed in. Tokens are never thrown away because a request failed. | `ios/SubletteTests/SessionModelTests.swift`, `TokenManagerTests.swift` |
| Server or email provider (iPhone app, signing up) | The screen shows the reason and the student can try again. | `ios/SubletteTests/OnboardingModelTests.swift` |
| Apple Maps search, for "My campus" (iPhone app) | "Maps can't be reached right now. Move the map yourself, or try again." The renter drags the map or taps to place the pin; the search saves without the shortcut. An unknown school says so the same way. | `ios/SubletteTests/PreferencesEditorModelTests.swift` |
| Server (iPhone app, renter search) | Loading the saved search offline keeps what was shown and offers a retry; saving offline keeps every answer in the flow. Nobody is signed out. | `ios/SubletteTests/PreferencesEditorModelTests.swift` (`RenterSearchModelTests`) |
| Sample room pictures for fake listings (`backend/app/data/seed_photos`) | `make seed-fake` still adds every listing and renter, with no photo files, and says so. | `backend/tests/test_deck.py` |
| PostGIS distance search (deck) | The migration turns PostGIS on, so a database without it fails at deploy. A database outage answers 503 like every `/v1` route. | `backend/tests/test_migrations.py`, `test_health.py` |
| Server, while swiping (iPhone app) | Swipes are kept on the phone, survive a relaunch, and go out in order when the connection is back, each with an id made on the phone so the server counts it once. A banner says so. Undo of a swipe still on the phone never reaches the server; undo of a sent one needs a connection and says so. Another account's queued swipes are never sent. | `ios/SubletteTests/SwipeTests.swift`, `backend/tests/test_swipes.py` |
| Server, on the map (iPhone app) | Pins already shown stay, with "Can't reach Sublette"; a like or pass from a pin is queued like any swipe, and the pin keeps its new state after a reload. | `ios/SubletteTests/MapTests.swift` |
| Apple's map tiles (iPhone app) | Not testable in unit tests: without tiles MapKit draws an empty grid, and the pins, the circle and the cards still work, because they come from Sublette's server. | Tried by hand |
| Photo storage (iPhone app) | "Couldn't upload the photo. You can add one later." The rest of the profile still saves. | `ios/SubletteTests/ProfileFormModelTests.swift`, `AuthorizedRequestTests.swift` |
| Apple Push Notification service (server, `httpx2` over HTTP/2, a `.p8` key signed with `cryptography`) | The message, match or listing is saved and the request answers at once: pushes are sent afterwards on their own threads, with a 10-second limit. Apple down, slow, answering garbage, or a broken key is logged and dropped; the app shows everything the next time it opens. A phone Apple says is gone is forgotten. | `backend/tests/test_push.py`, `test_chat.py` |
| `xcrun simctl push` (local server, simulator pushes) | No Xcode, a slow or stopped simulator, or garbage output: logged in the `make dev` window, nothing else changes. Hosted servers never run it and refuse simulator registrations. | `backend/tests/test_push.py`, `test_chat.py` |
| Live connection (iPhone app, WebSocket `/v1/ws`) | Chat still works without it: sending is a normal request, and each chat reloads when opened. The app reconnects on its own (1, 2, 4… up to 30 seconds apart), refreshes the token when the server asks (close code 4401), and reloads anything missed when it is back. A message that fails to send stays on screen with "Not sent. Try again", and a retry is stored once. | `ios/SubletteTests/ChatTests.swift`, `backend/tests/test_chat.py` |
| Notification permission (iPhone app) | Asked once, at the first match. Declining changes nothing else; chat works while the app is open. | `ios/SubletteTests/ChatTests.swift` (`NotificationsTests`) |
| Housekeeping thread (server: expiry, photo checks, clean-up) | A failed run (database or photo storage down) is logged and tried again 10 minutes later; requests are unaffected. The deck hides expired listings by date on its own, so a late run changes nothing students see. A photo storage can't read is checked next time. Two server processes never run it at once. | `backend/tests/test_housekeeping.py` |
| Server, when reporting or blocking (iPhone app) | The report sheet stays open with the reason, and nothing is lost; a block that fails changes nothing and says why. | `ios/SubletteTests/SafetyTests.swift` |

When a phase adds a dependency (email sending, photo storage, push, the language
model), it adds a row here and the tests behind it.

**2. When you rename a path, table, field or endpoint, search the whole repository for the old value.**

```sh
make find-refs VALUE=/v1/deck    # every place the old name lives, grouped by area
```

Record the rename in `docs/renames.toml`. From then on `make check` fails while
the old value appears anywhere it was not deliberately kept (code, tests,
migrations, scripts, docs, fixtures, comments, CI), and fails until the new
value appears in a test.

Three contracts stop the two codebases drifting apart:

- `docs/contract/endpoints.json`: the server's routes and the app's `Endpoint.swift` must both match it. Endpoints marked `auth` are tested to refuse a request with no token.
- `docs/contract/samples/*.json`: real server responses. The server's tests fail if it stops sending exactly these; the app's tests fail if its Swift models cannot decode them. After an intended API change, rewrite them with `UPDATE_CONTRACT_SAMPLES=1 make test`.
- `docs/contract/design-tokens.json`: the app's colors must match it, and each text and background pair is checked against WCAG contrast.

## Staging, for $0

Four free accounts, no credit card for any of them. Staging uses them like this:

| Piece | Free service | Free-plan limits that matter |
| --- | --- | --- |
| Code | GitHub, private repository | The iPhone CI job runs only on `main` to save macOS minutes |
| Database | Neon, PostgreSQL with PostGIS | 1 GB; sleeps after 5 idle minutes and wakes on the next query |
| Server | Render web service, set up from `render.yaml` | Sleeps after 15 idle minutes; the first request after that takes about a minute; outgoing SMTP is blocked |
| Email | Brevo, sending over HTTPS | 300 emails a day; a "Sent with Brevo" footer |
| Photos | Kept in the database (`SUBLETTE_STORAGE_BACKEND=database`) | Uses Neon's 1 GB; photos are shrunk to about 300 KB, so a few thousand fit |

Why not Render's own free database: it is deleted 30 days after creation.
Why photos in the database: Render's free disk is wiped on every restart, and
the free S3-style stores checked so far need a payment method for public files.
Moving to a real photo store later is a settings change (`s3`).

### Steps

1. **GitHub.** Create a private repository and push this folder to it.
2. **Neon.** Create a project (PostgreSQL 16, region AWS US West 2 (Oregon)) and copy its connection string with connection pooling turned off.
3. **Brevo.** Add a sender (an address you can open, such as a new Gmail account for the app) and verify it, then create an API key.
4. **Render.** New > Blueprint > choose the repository. Render reads `render.yaml` and asks for:
   | Variable | Value |
   | --- | --- |
   | `SUBLETTE_DATABASE_URL` | Neon's connection string |
   | `SUBLETTE_BREVO_API_KEY` | Brevo's API key |
   | `SUBLETTE_EMAIL_FROM` | `Sublette <the-sender-you-verified@gmail.com>` |
   `SUBLETTE_SECRET_KEY` is generated by Render. Migrations and the school list load on every start.
5. **Check it.** Open `https://<your-service>.onrender.com/health`. It should say `"status":"ok"`.
6. **Point the app at it.** In `ios/project.yml`, under `Staging`, set `SUBLETTE_API_BASE_URL` to that address. Run `make ios` and choose the **Sublette Staging** scheme. Staging waits up to 75 seconds for a request, so a sleeping server has time to wake.

A code sent from a free Gmail address can land in spam. Check there first. A
domain of your own (about $10 to $15 a year) fixes that later: verify it in
Brevo and change `SUBLETTE_EMAIL_FROM`. No code changes are needed.

The server refuses to start with a missing or wrong setting, and the reason is
at the end of Render's deploy log.

## Layout

```text
backend/
  app/            main.py  config.py  db.py  deps.py  errors.py  seed.py
                  models/  schemas/  routers/  services/  data/
  alembic/        database migrations
  tests/
ios/
  project.yml     the Xcode project is generated from this
  Sublette/
    App/          app entry, routing, mode state, header, tabs
    Core/         Networking  Auth  Storage  DesignSystem
    Features/     Onboarding  Deck  Map  Chat  Profile
    Resources/
  SubletteTests/
docs/
  contract/       endpoints.json  samples/  design-tokens.json
  renames.toml    the rename log
  decisions.md    choices made while building, and why
scripts/          check_renames.py  ios-test.sh
```

## Reviewing reports: the admin page

Reports from the app and the server's scam flags wait at `/admin`. To use it
on your Mac, add a password to `backend/.env` (in the `sublette` folder):

```
echo 'SUBLETTE_ADMIN_PASSWORD=pick-a-long-password-here' >> backend/.env
make dev
```

Then open http://localhost:8000/admin in Safari, sign in as `admin` with that
password, and you'll see the open reports, oldest first. From there you can
dismiss a report, suspend someone (they see your reason and how to appeal),
lift a suspension, or remove a listing. On staging, set the same variable in
Render's dashboard (16 characters or more).

To try it: sign in on a simulator, open a listing's "…" menu, tap "Report
this listing", and refresh the admin page.

## Push notifications on a real iPhone

Locally, pushes go to simulators (above) and are printed in the terminal.
Real phones need Apple Push Notification service, which needs a paid Apple
Developer account ($99 a year). Nothing is set up for that yet. When it is:

1. In the Apple Developer site, Keys > +, tick "Apple Push Notifications
   service", download the `.p8` file, and note its Key ID and your Team ID.
2. On the server set `SUBLETTE_PUSH_BACKEND=apns`, `SUBLETTE_APNS_TEAM_ID`,
   `SUBLETTE_APNS_KEY_ID` and `SUBLETTE_APNS_PRIVATE_KEY` (the file's text) or
   `SUBLETTE_APNS_PRIVATE_KEY_PATH`.

## Conventions

- REST under `/v1`, JSON with snake_case keys, errors as `{code, message}`. Validation errors add `fields`.
- Times in UTC ISO 8601. Money as integer cents. Distances in meters.
- Every server rule has a pytest test. Every iPhone screen has a SwiftUI preview.
- Nothing in the code is specific to one school or one city.
- Ink text on yellow and orange. Never white.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `make db` fails with "port is already allocated" | Another PostgreSQL is using port 5432. Stop it, or change the port in `docker-compose.yml` and `SUBLETTE_DATABASE_URL`. |
| Tests fail with "The test database is not reachable" | Run `make db`. |
| The app says "Can't reach Sublette" | Run `make dev`, then try again. |
| No code arrives by email | In development none is sent. Read it from the `make dev` terminal. |
| "Too many tries" while testing | Limits are per email and per hour. Use another made-up `.edu` address, or `make db-reset`. |
| A real iPhone can't reach the server | `localhost` on a phone is the phone. Run `HOST=0.0.0.0 make run`, set `SUBLETTE_PUBLIC_BASE_URL=http://<your-mac-name>.local:8000` in `backend/.env`, and use the same address for Debug in `ios/project.yml`. |
| No notification in the simulator | Allow notifications when the app asks (at the first match), check the `make dev` window shows "Push to phone", and that the other simulator is on its Home screen. Messages to an open app arrive live, not as a push. |
| A new Swift file is missing in Xcode | Run `make ios` again. The project is generated from the folders. |
| http://localhost:8000/admin says "Not Found" | Set `SUBLETTE_ADMIN_PASSWORD` in `backend/.env` and restart `make dev`. |
| The app shows "Before you start" | Each new version of the terms asks once. Tap "I agree". |
