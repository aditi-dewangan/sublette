# Sublette: one place for every command. Run `make` to list them.

PYTHON ?= python3.12
VENV   := backend/.venv
BIN    := $(VENV)/bin
HOST   ?= 127.0.0.1
PORT   ?= 8000

.DEFAULT_GOAL := help
.PHONY: help setup dev db db-stop db-reset migrate seed-fake run test lint fmt check find-refs ios ios-test

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

setup: ## Install the server's Python packages (run once)
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install --quiet --upgrade pip
	$(BIN)/pip install --quiet -e "backend[dev]"
	@echo "Done. Next: make dev"

dev: db migrate run ## Start the database and the server (the one command you need)

db: ## Start the local database
	docker compose up --detach --wait db

db-stop: ## Stop the local database, keeping its data
	docker compose stop db

db-reset: ## Delete all local data and start a fresh database
	docker compose down --volumes
	$(MAKE) db

migrate: ## Apply database migrations and load the list of schools
	cd backend && .venv/bin/alembic upgrade head && .venv/bin/python -m app.seed

seed-fake: ## Add 1,000 fake listings and 200 fake renters (ARGS=--remove to take them out)
	cd backend && .venv/bin/python -m app.seed_fake $(ARGS)

run: ## Start the server at http://localhost:8000 (HOST=0.0.0.0 to reach it from a real iPhone)
	cd backend && .venv/bin/uvicorn app.main:app --reload --host $(HOST) --port $(PORT)

test: ## Run the server tests (needs the database: make db)
	cd backend && .venv/bin/pytest

lint: ## Check code style and the rename log
	$(BIN)/ruff check backend scripts
	$(BIN)/ruff format --check backend scripts
	$(BIN)/python scripts/check_renames.py

fmt: ## Format the Python code
	$(BIN)/ruff check --fix backend scripts
	$(BIN)/ruff format backend scripts

check: lint test ## Everything CI runs for the server

find-refs: ## List every place a name appears: make find-refs VALUE=/v1/deck
	@test -n "$(VALUE)" || (echo "Usage: make find-refs VALUE=the_old_name" && exit 1)
	@$(BIN)/python scripts/check_renames.py find "$(VALUE)"

ios: ## Generate the Xcode project and open it (Mac only)
	cd ios && xcodegen generate && open Sublette.xcodeproj

ios-test: ## Build the iPhone app and run its tests in a simulator (Mac only)
	./scripts/ios-test.sh
