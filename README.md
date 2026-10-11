# Sublette

An iPhone app that matches college students who need a short-term place with
students who need someone to take over their lease. Any `.edu` email can join.

- `ios/` is the iPhone app: Swift and SwiftUI, iOS 17 or later.
- `backend/` is the server: Python 3.12, FastAPI, PostgreSQL 16 with PostGIS.
- `docs/` holds the contracts both codebases are tested against, the rename log and decisions.

## Build status

| Phase | What it delivers | Status |
| --- | --- | --- |
| 0 | Scaffolding: both codebases run and talk to each other | Built. Server verified. iPhone app not yet compiled (see below). |
| 1 | Accounts and .edu email verification | Next |
| 2 to 10 | Lister mode through the AI recommender | Not started |

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
# {"status":"ok","version":"0.1.0","environment":"local","database":{"reachable":true,"postgis":"3.4.2"}}
```

Interactive API docs are at http://localhost:8000/docs.

In a second terminal, open the iPhone app:

```sh
make ios
```

Pick an iPhone simulator and press Run. The Deck tab shows a card with what
`/health` answered. The switch in the header flips between Renter mode (yellow)
and Lister mode (orange).

Run `make` with no arguments to list every command.

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

Two contract files stop the two codebases drifting apart:

- `docs/contract/endpoints.json`: the server's routes and the app's `Endpoint.swift` must both match it.
- `docs/contract/design-tokens.json`: the app's colors must match it, and each text and background pair is checked against WCAG contrast.

## Staging

The server ships as a container (`backend/Dockerfile`). It needs two settings:

| Variable | Value |
| --- | --- |
| `SUBLETTE_ENV` | `staging` |
| `SUBLETTE_DATABASE_URL` | The staging database's URL. `postgres://` and `postgresql://` forms are accepted. |

The database must be PostgreSQL 16 with the PostGIS extension enabled.
Migrations run on start. Once deployed, put the server's address in
`ios/project.yml` under `Staging` > `SUBLETTE_API_BASE_URL`, run `make ios`, and
run the **Sublette Staging** scheme.

## Layout

```text
backend/
  app/            main.py  config.py  db.py  errors.py
                  models/  schemas/  routers/  services/
  alembic/        database migrations
  tests/
ios/
  project.yml     the Xcode project is generated from this
  Sublette/
    App/          app entry, mode state, header, tabs
    Core/         Networking  Auth  DesignSystem
    Features/     Deck  Map  Chat  Profile
    Resources/
  SubletteTests/
docs/
  contract/       endpoints.json  design-tokens.json
  renames.toml    the rename log
  decisions.md    choices made while building, and why
scripts/          check_renames.py  ios-test.sh
```

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
| The app's card says "Can't reach the server" | Run `make dev` and tap **Check again**. |
| A real iPhone can't reach the server | Run `HOST=0.0.0.0 make run`, and set the Debug address in `ios/project.yml` to your Mac's local network address. |
| A new Swift file is missing in Xcode | Run `make ios` again. The project is generated from the folders. |
