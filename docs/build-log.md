# Build log

Where the build stands, so any new session (or person) can pick up without the
original chat. Requirements come from the "Sublette: Product and Business
Spec" doc; its Build plan tab defines phases 0 to 10 and each phase's
"Done when" list. Choices and open questions are in `docs/decisions.md`.

| Phase | Status |
| --- | --- |
| 0 Scaffolding | Signed off 2026-10-10: builds, runs and tests pass on Aditi's Mac. On `main`. |
| 1 Accounts and .edu verification | Merged (#1). |
| 2 Lister mode | Merged (#2). |
| Dev email inbox | Merged (#3). |
| 3 Renter mode and the toggle | Merged (#4). |
| 4 Matching engine | Merged (#6; #5 had landed on `phase-3` by mistake). |
| 5 Swipe decks and matches | Merged (#7). |
| 6 Map and pins | Pull request #8 (`phase-6`). |
| 7 Chat, checklist and notifications | Next. |

## How each phase is delivered

1. Build only that phase, with the tests its "Done when" list names.
2. Follow `CLAUDE.md`: test every new dependency when it is unavailable; search the whole repository on every rename and log it in `docs/renames.toml`.
3. Push a `phase-N` branch and open a pull request. GitHub runs the server checks on every push; start the iPhone build from the Actions tab (or it runs on `main`). Aditi tries the phase on her Mac, then merges.

## Staging ($0)

Planned, not yet deployed: Neon (database), Render from `render.yaml` (server),
Brevo over HTTPS (email, because Render's free plan blocks SMTP), photos kept
in the database.
Steps are in `README.md`, "Staging, for $0".

## Waiting on Aditi

- Trying Phase 6: `make seed-fake`, put your pin near UW, open the Map tab. Zoom out (numbers), zoom in (pins), tap a pin and like it (it turns into a heart and leaves the deck), move the pin from the map. Then merge #8.
