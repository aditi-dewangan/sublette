# Build log

Where the build stands, so any new session (or person) can pick up without the
original chat. Requirements come from the "Sublette: Product and Business
Spec" doc; its Build plan tab defines phases 0 to 10 and each phase's
"Done when" list. Choices and open questions are in `docs/decisions.md`.

| Phase | Status |
| --- | --- |
| 0 Scaffolding | Signed off 2026-10-10: builds, runs and tests pass on Aditi's Mac. On `main`. |
| 1 Accounts and .edu verification | Built on branch `phase-1`. Server verified (220 tests). iPhone code reviewed by reading only; waiting for Aditi's Mac build and sign-off. |
| 2 Lister mode | Not started. |

## How each phase is delivered

1. Build only that phase, with the tests its "Done when" list names.
2. Follow `CLAUDE.md`: test every new dependency when it is unavailable; search the whole repository on every rename and log it in `docs/renames.toml`.
3. Push a `phase-N` branch and open a pull request. Aditi runs `make check` and `make ios-test` on her Mac, then merges.

## Staging ($0)

Planned, not yet deployed: Neon (database), Render from `render.yaml` (server),
Brevo over HTTPS (email, because Render's free plan blocks SMTP), photos off.
Steps are in `README.md`, "Staging, for $0".

## Waiting on Aditi

- Phase 1 result from `make ios-test` on her Mac.
- Should a profile photo be required before swiping? (Optional now.)
- Phase 2: add a "quiet hours" field to listings, or drop it? The spec has it; the build plan's table does not.
