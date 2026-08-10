# Single entry point for every local command in this repository.
#
# Convention: make is the discoverable front door, scripts hold the logic.
# Any recipe longer than three lines, or needing a conditional or a loop,
# becomes a script under scripts/ and the target only calls it. Phase 10's
# ordered teardown is the reason — that is real shell, not a make recipe.
#
# Targets are added by the phase that makes them work. Commands listed under
# "Planned" below are not yet implemented; declaring them as stub targets
# would make `make help` lie about what runs.
#
# Note: macOS ships GNU Make 3.81, which has no .ONESHELL or .RECIPEPREFIX.
# The three-line rule above means neither is needed. Recipes use literal tabs.

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

AWS_PROFILE ?= bootcamp-administrator-access
AWS_REGION  ?= us-east-1
AWS_ACCOUNT_ID ?= 590184028094
APP_DIR := app
VENV    := $(CURDIR)/$(APP_DIR)/.venv
PY      := $(VENV)/bin/python
PIP     := $(VENV)/bin/pip
RUFF    := $(VENV)/bin/ruff
export AWS_PROFILE AWS_REGION AWS_ACCOUNT_ID

$(VENV)/bin/python:
	@./scripts/create-venv.sh

# Every target here is phony — it names an action, not a file it produces.
# Each declares itself immediately above its own rule rather than in one
# central list, so a target and its declaration cannot drift apart as later
# phases add to this file. An undeclared target silently stops running the
# moment a file or directory of the same name appears, reporting success.
#
# Note for Phase 3: .PHONY does not accept pattern rules, so `plan-%` and
# `apply-%` will need `plan-%: FORCE` with an empty `FORCE:` target instead.

.PHONY: help
help: ## Show available commands
	@printf '\n  \033[1mblue/green deployment platform\033[0m\n'
	@printf '  Usage: make <target>\n\n  \033[1mAvailable now\033[0m\n'
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "    \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\n  \033[1mPlanned\033[0m \033[2m(arrives with the phase noted)\033[0m\n'
	@sed -n 's/^# PLANNED: //p' $(MAKEFILE_LIST) \
	  | awk '{n=$$1; $$1=""; sub(/^[ \t]+/,""); printf "    \033[2m%-14s %s\033[0m\n", n, $$0}'
	@printf '\n'

.PHONY: verify
verify: verify-tools verify-aws ## Run every Phase 0 verification check

.PHONY: verify-tools
verify-tools: ## Check the local toolchain and version pins
	@./scripts/verify-tools.sh

.PHONY: verify-aws
verify-aws: ## Confirm the AWS session, account and region
	@./scripts/verify-aws.sh

# ---------------------------------------------------------------------------
# Phase 1 — application
#
# Every recipe calls the virtualenv's interpreter by path. `python3` on PATH is
# 3.14.6 only when make's parent was a zsh; from CI, a git hook or an editor
# task it is the system 3.12. See docs/phases/phase1/…-implementation-plan.md §F1.
# ---------------------------------------------------------------------------

.PHONY: venv
venv: $(VENV)/bin/python ## Create the virtualenv on the pinned interpreter

$(VENV)/.deps-stamp: $(APP_DIR)/requirements-dev.txt | $(VENV)/bin/python
	@$(PIP) install --require-hashes --quiet -r $(APP_DIR)/requirements-dev.txt
	@touch $@

.PHONY: deps
deps: $(VENV)/.deps-stamp ## Install hash-pinned dependencies into the virtualenv

.PHONY: deps-compile
deps-compile: venv ## Recompile both requirements locks with hashes
	@./scripts/compile-deps.sh

.PHONY: local-up
local-up: ## Start DynamoDB Local
	@cd $(APP_DIR) && docker compose up -d

.PHONY: local-down
local-down: ## Stop DynamoDB Local and discard its data
	@cd $(APP_DIR) && docker compose down -v

# Depends on local-up because the contract suite runs against DynamoDB Local.
# `docker compose up -d` is idempotent and returns in milliseconds when the
# container is already running, so this costs nothing on repeat runs.
.PHONY: test
test: deps local-up ## Run the application test suite with coverage
	@cd $(APP_DIR) && $(PY) -m pytest

.PHONY: lint
lint: deps ## Ruff lint and format check
	@cd $(APP_DIR) && $(RUFF) check . && $(RUFF) format --check .

.PHONY: format
format: deps ## Apply ruff formatting and safe fixes
	@cd $(APP_DIR) && $(RUFF) check --fix . && $(RUFF) format .

# PYTHONPATH=src, because the package is deliberately never pip-installed.
# pytest gets there via `pythonpath = ["src"]` in pyproject.toml, but that
# setting is pytest's alone — python -m and uvicorn know nothing about it.
# Phase 2's image sets PYTHONPATH=/app/src for exactly the same reason, so
# these two recipes run the application the way the container will.
.PHONY: local-tables
local-tables: deps local-up ## Create the local DynamoDB tables (idempotent)
	@cd $(APP_DIR) && PYTHONPATH=src $(PY) -m bgd.cli.create_tables

.PHONY: run-local
run-local: local-tables ## Run the API against DynamoDB Local
	@cd $(APP_DIR) && PYTHONPATH=src $(PY) -m uvicorn bgd.api.main:create_app \
	  --factory --reload --port 8080

# PLANNED: build          Build the container image (Phase 2)
# PLANNED: sbom           Generate the SBOM with syft (Phase 2)
# PLANNED: plan-LAYER     terraform plan for one layer (Phase 3)
# PLANNED: apply-LAYER    terraform apply for one layer (Phase 3)
# PLANNED: seed-ecr       Push the first real image to ECR (Phase 3)
# PLANNED: smoke          Smoke test an environment over TLS (Phase 5)
# PLANNED: teardown       Destroy prod then staging then network (Phase 10)
# PLANNED: rebuild        Apply network then staging then prod (Phase 10)
