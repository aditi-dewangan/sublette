# Sublette: context for continuing the build

Read this first in any new session. It says where the build stands, how Aditi
wants the work done, and what has already been decided, so you can pick up the
next phase without the original conversations.

Then read, in this order: `CLAUDE.md` (rules for every change), `README.md`
(setup, commands, the dependency table), `docs/build-plan.md` (the phases still
to build), `docs/decisions.md` (every choice made so far, with reasons) and
`docs/build-log.md` (phase status).

## The product

Sublette is an iPhone app for college students to sublet rooms. Anyone with a
`.edu` email can join, at any school. One account has two modes:

- **Renter mode (yellow):** set dates, budget, must-haves and a map pin; swipe
  on listings.
- **Lister mode (orange):** post a room with filters for who can take it; swipe
  on renters who liked it.

Two likes make a match, which opens a chat (phase 7). Rent and the sublease are
handled outside the app; there are no payments.

## Who you're working with

Aditi (aditidew@uw.edu) owns the product and the repository
(https://github.com/aditi-dewangan/sublette). She is not a professional
developer: explain setup steps as exact Terminal commands, say which folder to
run them in, and keep replies plain. She runs the server and the iPhone app on
her Mac and tests in the Xcode simulator.

## How to work

1. **One phase at a time.** Build only the next phase in `docs/build-plan.md`,
   with the tests its "Done when" list names. Stop and confirm with Aditi when
   it's done. Don't start the next phase without her go-ahead.
2. **A branch and a pull request per phase**, named `phase-N`, always with
   `main` as the base. (A pull request stacked on another branch once merged
   into that branch instead of `main`; never stack.) Aditi merges.
3. **Before every push, run `make check`** (lint, format, rename log, all
   server tests). It needs the database: `make db`.
4. **The iPhone build runs on GitHub only on `main` or when started by hand.**
   After pushing a phase branch, start it with
   `gh workflow run CI --ref phase-N` and wait for both jobs to pass. On a Mac,
   `make ios-test` runs it locally. Swift can't be compiled on Linux, so a
   cloud session must rely on this CI job.
5. **Her two mentor habits are rules here** (also in `CLAUDE.md`):
   - New dependency: test what happens when it is down, slow, or returns
     garbage; the core feature must still work or fail with a clear message.
     Add a row to the dependency table in `README.md`.
   - Rename: run `make find-refs VALUE=<old>`, update or deliberately keep every
     occurrence, record it in `docs/renames.toml`, and add a test for the new
     name. Removing a file counts.
6. **Record decisions** you make on her behalf in `docs/decisions.md` under a
   heading for the phase, and update `docs/build-log.md` and the status table
   in `README.md` when a phase is done. In the pull request, list every
   "Done when" line with the test that proves it, and say plainly which ones
   only she can check (for example, trying it on two simulators).
7. **Everything stays $0 to start.** Prefer free tiers and built-in Apple
   services. Ask before adding anything that costs money.

## Where the build stands (2026-10-19)

| Phase | State |
| --- | --- |
| 0 Scaffolding | Merged |
| 1 Accounts and `.edu` verification | Merged |
| 2 Lister mode | Merged |
| 3 Renter mode and the mode toggle | Merged |
| 4 Matching engine | Merged |
| 5 Swipe decks and matches | Merged |
| 6 Map and pins | Pull request #8 (`phase-6`), every check passing. Also carries Aditi's feedback changes below. Waiting for her to merge. |
| 7 Chat, checklist and notifications | **Next** |
| 8 to 10 | Not started |

If #8 is still open when you start, check with Aditi before branching
`phase-7` from `main`.

### Changes Aditi asked for after trying phases 5 and 6 (all in #8)

- **No percentages.** Cards show "Great fit", "Good fit" or nothing, plus one
  plain sentence (`summary`). `score` stays in the API for ordering and pin
  colors only.
- **Must-haves are never questioned.** The empty deck explains what rules
  places out and offers "Notify me" and "Search a bigger area"; it never
  suggests turning a must-have into a nice-to-have.
- **The budget is a hard limit.** A listing over `max_rent_cents` is ineligible
  (`max_rent` in diagnostics).
- **Codes in the terminal.** A local server prints every sign-in code in the
  `make dev` terminal as well as emailing it; a failed email still lets her
  sign in with the printed code. Refused in production.

## Product decisions Aditi has made

- Stack from the build plan; no Firebase.
- Profile photos are optional. "Quiet hours" was dropped.
- Bundle ID `app.sublette.Sublette` for now.
- Gender: renters may state woman, man or non-binary (optional). Listers of a
  shared home choose who can take it: women, men, or no preference. A
  non-binary renter fits places for women and for men. A renter who hasn't
  stated a gender can't see places with a preference, and is told why.
- Renters can also choose who they'd live with (women, men, no preference, as
  must or nice); listers say who the housemates staying are (women, men,
  mixed).
- Development sign-in email goes through Brevo from
  `subletteofficial@gmail.com`. `SUBLETTE_EMAIL_REDIRECT_TO` can send every
  code to one inbox (her Gmail `DEV` label); without it codes go to the typed
  address.

## The code, in one page

```
backend/                FastAPI server (Python 3.12)
  app/routers/          one file per area: auth, me, uploads, files, listings,
                        renter_profile, deck, swipes, maps, health
  app/services/         the rules: matching.py (is_eligible, score, reasons,
                        summary, score_band), deck.py, swipes.py, maps.py,
                        listings.py, preferences.py, storage.py, email_sender.py
  app/models/           SQLAlchemy tables: users, schools, email_codes,
                        rate_limit_hits, stored_files, listings, listing_photos,
                        renter_profiles, swipes, matches, saved_listings
  alembic/versions/     migrations 0001 to 0006 (PostGIS turned on in 0003)
  app/seed_fake.py      `make seed-fake`: 1,000 listings and 200 renters
  tests/                pytest against a real PostgreSQL + PostGIS database
ios/                    SwiftUI app, iOS 17, generated by XcodeGen (project.yml)
  Sublette/App/         AppContainer (builds every model), RootView (tabs per
                        mode), AppState (mode), PreviewSupport (fakes for previews)
  Sublette/Core/        Networking (APIClient, Endpoint.swift = every path),
                        Auth, Listings, Renter, Deck (SwipeOutbox), Map, DesignSystem
  Sublette/Features/    Onboarding, Profile, Lister, Renter, Deck, Map
  SubletteTests/        XCTest; TestSupport.swift holds the stub APIs
docs/contract/          endpoints.json (every route), samples/*.json (real
                        responses, decoded by the Swift tests), design-tokens.json
```

Patterns to keep:

- **Every endpoint** goes in `docs/contract/endpoints.json`, the server and
  `Endpoint.swift`, with a real response in `docs/contract/samples/` (write it
  with `UPDATE_CONTRACT_SAMPLES=1 make test`) decoded in a Swift test.
- **Privacy rules live on the server and have a test that sweeps every GET
  endpoint** in `endpoints.json`: no user's pin reaches another user
  (`test_renter_profile.py`), and only the owner and a matched renter get a
  listing's exact location (`test_map.py`). New endpoints are covered
  automatically; keep it that way.
- **Swipes are idempotent.** The app makes a `swipe_id`; the database's unique
  constraints make resends harmless; the app's `SwipeOutbox` keeps swipes made
  offline (per account) and sends them in order.
- **Screen models** are `@MainActor @Observable` classes with a protocol-typed
  API, created once in `AppContainer`, with a `prepare(for: userID)` that
  forgets another account's data. Each screen has a `#Preview` using
  `PreviewSupport.swift`.
- **The clock** comes from the `Now` dependency; tests move it with `Clock`.

## Known gaps to pick up

- Listings don't expire yet, and photos uploaded in an abandoned editor stay in
  storage: both belong with phase 8's background job.
- Blocked users aren't excluded from decks and the map yet: the spot is marked
  in `services/deck.py` (phase 8).
- `notify_new_listings` is saved but nothing is sent: phase 7's push.
- Staging (Render + Neon + Brevo, `render.yaml`) is written but not deployed.
- Sign-in emails from a Gmail sender may land in school spam folders; a
  domain of our own fixes it before launch.
- No App Store privacy manifest yet (phase 9).
