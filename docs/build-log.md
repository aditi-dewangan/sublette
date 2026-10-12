# Build log

Where the build stands, so any new session (or person) can pick up without the
original chat. Requirements come from the "Sublette: Product and Business
Spec" doc; its Build plan tab defines phases 0 to 10 and each phase's
"Done when" list. Choices and open questions are in `docs/decisions.md`.

| Phase | Status |
| --- | --- |
| 0 Scaffolding | Signed off 2026-10-10: builds, runs and tests pass on Aditi's Mac. On `main`. |
| 1 Accounts and .edu verification | Pull request #1 (`phase-1`). All checks pass on GitHub, including the iPhone build and its unit tests on GitHub's Mac. Waiting for Aditi to try it in the simulator and merge. |
| 2 Lister mode | Not started. |

## How each phase is delivered

1. Build only that phase, with the tests its "Done when" list names.
2. Follow `CLAUDE.md`: test every new dependency when it is unavailable; search the whole repository on every rename and log it in `docs/renames.toml`.
3. Push a `phase-N` branch and open a pull request. GitHub runs the server checks on every push; start the iPhone build from the Actions tab (or it runs on `main`). Aditi tries the phase on her Mac, then merges.

## Staging ($0)

Planned, not yet deployed: Neon (database), Render from `render.yaml` (server),
Brevo over HTTPS (email, because Render's free plan blocks SMTP), photos off.
Steps are in `README.md`, "Staging, for $0".

## Waiting on Aditi

- Trying Phase 1 in the simulator (sign up, reopen, delete) and merging pull request #1.
- Should a profile photo be required before swiping? (Optional now.)
- Phase 2: add a "quiet hours" field to listings, or drop it? The spec has it; the build plan's table does not.
