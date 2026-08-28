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

# := rather than ?=, deliberately, and this is load-bearing from Phase 3 on.
# GNU Make gives an environment variable precedence over ?=, so a shell that
# already exports AWS_PROFILE for some other account silently wins — and
# `make apply-foundation` would then run Terraform against that account. A :=
# assignment overrides the environment while still yielding to an explicit
# `make AWS_PROFILE=other <target>` on the command line, which is the only
# override that should count. Found in Phase 3; see
# docs/phases/phase3/2026-08-24-local-verification.md §F7.
AWS_PROFILE := bootcamp-administrator-access
AWS_REGION  := us-east-1
AWS_ACCOUNT_ID := 590184028094
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
	@sed -n 's/^# LISTED: //p' $(MAKEFILE_LIST) \
	  | awk '{n=$$1; $$1=""; sub(/^[ \t]+/,""); printf "    \033[36m%-14s\033[0m %s\n", n, $$0}'
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

# ---------------------------------------------------------------------------
# Phase 2 — container image
#
# The build itself lives in scripts/, because reproducibility needs a specific
# buildx driver, two exporters and timestamps derived from git — none of which
# fits a three-line recipe. See docs/phases/phase2/…-implementation-plan.md.
# ---------------------------------------------------------------------------

.PHONY: build
build: ## Build the container image reproducibly and record its digest
	@./scripts/build-image.sh

# --no-cov: the container is a separate process, so it executes none of the
# lines coverage measures, and the 90% gate would fail for an unrelated reason.
.PHONY: image-test
image-test: deps build local-tables ## Run the image suite against the built container
	@cd $(APP_DIR) && $(PY) -m pytest -m image --no-cov

.PHONY: sbom
sbom: build ## Generate the SBOM for the built image with syft
	@./scripts/generate-sbom.sh

.PHONY: image-verify
image-verify: ## Prove two clean builds produce the same image digest
	@./scripts/verify-image-repeatability.sh

.PHONY: run-image
run-image: build local-tables ## Run the built image against DynamoDB Local on :8081
	@./scripts/run-image.sh

# ---------------------------------------------------------------------------
# Phase 3 — Terraform
#
# fmt, validate, lint and test need no AWS session: scripts/tf.sh initialises
# them with -backend=false, so the whole gate runs on a machine that has never
# logged in. Only plan and apply reach the account. See
# docs/phases/phase3/2026-08-24-phase-03-implementation-plan.md §F2.
#
# Add a layer here as the phase that creates it lands: network (4),
# staging (5), prod (6).
# ---------------------------------------------------------------------------

TF_LAYERS := bootstrap foundation network

.PHONY: tf-fmt
tf-fmt: ## Format every Terraform file in place
	@terraform fmt -recursive infra

.PHONY: tf-validate
tf-validate: ## Validate every Terraform layer (no AWS session needed)
	@for l in $(TF_LAYERS); do ./scripts/tf.sh validate $$l; done

.PHONY: tf-test
tf-test: ## Run the Terraform test suites against mocked providers
	@for l in $(TF_LAYERS); do ./scripts/tf.sh test $$l; done

.PHONY: tf-lint
tf-lint: ## Run tflint and checkov from digest-pinned containers
	@./scripts/lint-infra.sh $(TF_LAYERS)

.PHONY: tf-check
tf-check: tf-validate tf-lint tf-test ## The full pre-merge gate for infra/ (no AWS session)
	@printf '\n  all infra checks passed\n\n'

# Pattern rules cannot be declared .PHONY, so they depend on an always-missing
# target instead. Without FORCE, `make plan-foundation` would silently stop
# running the day a file named plan-foundation appears — and report success.
# The makefile's own note to Phase 3 called this out.
FORCE:

# LISTED: plan-LAYER     terraform plan for one layer (needs an AWS session)
plan-%: FORCE
	@./scripts/tf.sh plan $*

# LISTED: apply-LAYER    terraform apply for one layer (needs an AWS session)
apply-%: FORCE
	@./scripts/tf.sh apply $*

.PHONY: seed-ecr
seed-ecr: ## Push the built image into ECR (needs an AWS session)
	@./scripts/seed-ecr.sh

# ---------------------------------------------------------------------------
# Phase 4 — network
# ---------------------------------------------------------------------------

.PHONY: teardown
teardown: ## Destroy prod, then staging, then network (needs an AWS session)
	@./scripts/teardown.sh

.PHONY: verify-network
verify-network: ## Prove a private subnet egresses through the NAT (needs an AWS session)
	@./scripts/verify-network.sh

# PLANNED: smoke          Smoke test an environment over TLS (Phase 5)
# PLANNED: rebuild        Apply network then staging then prod (Phase 10)
