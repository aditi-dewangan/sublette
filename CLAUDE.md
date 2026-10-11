# Working on Sublette

Read `README.md` first. The product spec and the eleven-phase build plan live in
the "Sublette: Product and Business Spec" doc; build one phase at a time and
stop for sign-off when its "Done when" list is true.

## Rules for every change

1. **New dependency: test it unavailable.** Any new service, SDK, script or
   external file gets a test for what happens when it is down, slow, or returns
   garbage. The core feature must keep working or fail with a clear message.
   Add a row to the dependency table in `README.md`.
2. **Rename: search everything.** Before renaming a path, endpoint, table,
   column, JSON field, setting or file, run `make find-refs VALUE=<old>`.
   Update or deliberately keep every occurrence (code, tests, migrations,
   scripts, docs, fixtures, comments, CI), record it in `docs/renames.toml`,
   and add a test that uses the new name.
3. **New endpoint:** add it to `docs/contract/endpoints.json`, to the server,
   and to `ios/Sublette/Core/Networking/Endpoint.swift`. No path strings
   anywhere else in the app.
4. **Server rules live on the server.** Filters, eligibility and privacy rules
   (exact address, renter pin) are enforced and tested in `backend/`, never
   only in the app.
5. Run `make check` before calling anything done. On a Mac, also `make ios-test`.

## Conventions

- REST under `/v1`; snake_case JSON; errors as `{code, message}` (+ `fields` on 422).
- UTC ISO 8601 times, integer cents, meters.
- Server: FastAPI, sync SQLAlchemy 2 with psycopg 3, Alembic, pytest, ruff.
- App: SwiftUI, iOS 17+, `@Observable` view models, async/await, a `#Preview` per screen.
- Colors come from `Brand`. Ink text on yellow and orange, never white.
- Nothing specific to one school or city.

See `docs/decisions.md` for choices already made.
