COMPOSE_DEV  = -f .infra/compose/docker-compose.dev.yml --env-file .env
COMPOSE_PROD = -f .infra/compose/docker-compose.production.yml --env-file .env

# Shorthands so the long invocation appears once.
DC_DEV  = docker compose $(COMPOSE_DEV)
DC_PROD = docker compose $(COMPOSE_PROD)

# The app services (web/api/worker) live behind the "apps" compose profile.
# Anything that must SEE them — logs, down, ps, exec — has to opt in, otherwise
# compose behaves as if they were not declared at all.
DC_DEV_APPS = $(DC_DEV) --profile apps

# Every target is a command, not a file. Without this, a target would be skipped
# if a file of the same name ever appeared in the repo root.
.PHONY: help \
        dciup-dev dciup-all dci-api dci-web dci-worker \
        dci-dev-build dci-down dci-down-clean dci-logs-dev dci-ps \
        dciup-prod dci-prod-build dci-down-prod dci-down-prod-clean dci-logs-prod \
        dci-api-shell dci-web-shell dci-db-shell dci-reset \
        check-submodules git-spull dci-dev-rebuild

# Default target: `make` with no arguments prints this list.
.DEFAULT_GOAL := help

help:
	@echo "Dev workflow — four terminals:"
	@echo "  make dciup-dev     Terminal 0: infra only (nginx, db, redis, minio)"
	@echo "  make dci-api       Terminal 1: NestJS API, logs attached"
	@echo "  make dci-web       Terminal 2: Next.js, logs attached"
	@echo "  make dci-worker    Terminal 3: BullMQ worker, logs attached"
	@echo ""
	@echo "  make dciup-all     Everything detached (demo / onboarding)"
	@echo "  make dci-logs-dev  Follow logs of every service, app services included"
	@echo "  make dci-ps        Status of every service"
	@echo "  make dci-dev-build Rebuild dev images (after a dependency change)"
	@echo "  make dci-down      Stop the whole dev stack"
	@echo ""
	@echo "  make git-spull     Pull this repo + fast-forward both submodules"
	@echo ""
	@echo "  http://frontend.inkwell.ai   app      (also http://localhost:8080)"
	@echo "  http://backend.inkwell.ai    API + /api/docs"
	@echo "  http://storage.inkwell.ai    MinIO S3 endpoint"
	@echo "  http://localhost:9001        MinIO console"

# ── Submodules ──────────────────────────────────────────────────────────────
# The app source lives in src/ as git submodules. A clone made without
# --recurse-submodules leaves those directories EMPTY, and Docker happily
# bind-mounts an empty dir — the container then dies on a missing package.json
# with no hint as to why. Fail loudly here instead.
check-submodules:
	@for d in frontend.inkwell.ai backend.inkwell.ai; do \
		test -f src/$$d/package.json || { \
			echo "ERROR: src/$$d is empty — run: git submodule update --init --recursive"; \
			exit 1; \
		}; \
	done

# Pull this repo, then fast-forward each submodule to the branch declared in
# .gitmodules (main for both). Committing the resulting pointer bump is a
# separate, deliberate step — that commit is what pins the deployable revision.
git-spull:
	git pull origin $$(git rev-parse --abbrev-ref HEAD)
	git submodule sync --recursive
	git submodule update --init --remote --recursive

# ── Dev ─────────────────────────────────────────────────────────────────────
# Infrastructure only: nginx, db, redis, minio. The app services are NOT started
# here — run each one in its own terminal with the targets below so you can
# restart, attach a debugger to, or read the logs of one without touching the
# others.
dciup-dev:
	$(DC_DEV) up -d

# One service, one terminal, logs streaming.
#
# `up --attach X ... X` starts X plus its declared dependencies but streams only
# X's output; Ctrl+C then stops just this service and leaves the rest of the
# stack running. --menu=false suppresses compose's interactive shortcut bar,
# which otherwise sits on top of the logs.
dci-api: check-submodules
	$(DC_DEV) up --attach api --menu=false api

dci-web: check-submodules
	$(DC_DEV) up --attach web --menu=false web

dci-worker: check-submodules
	$(DC_DEV) up --attach worker --menu=false worker

# The old `dciup-dev` behaviour: the entire stack detached in one command. Handy
# for a demo or a first-run smoke test, where per-service control does not matter.
dciup-all: check-submodules
	$(DC_DEV_APPS) up -d

# Rebuild the dev images. Needed after a dependency change: package.json and the
# lockfile are baked into a cached layer, so a new dependency is not visible to a
# running container until the image is rebuilt.
#
# Cached, not --no-cache — an ordinary dependency bump reuses every layer up to
# the install and takes seconds. Use dci-dev-rebuild for the from-scratch case.
dci-dev-build: check-submodules
	$(DC_DEV_APPS) build

# From scratch, ignoring every cached layer. For when a build is wedged, not for
# routine dependency changes.
dci-dev-rebuild: check-submodules
	$(DC_DEV_APPS) build --no-cache

dci-down:
	$(DC_DEV_APPS) down

dci-down-clean:
	$(DC_DEV_APPS) down -v

dci-logs-dev:
	$(DC_DEV_APPS) logs -f

dci-ps:
	$(DC_DEV_APPS) ps

# ── Prod ────────────────────────────────────────────────────────────────────
dciup-prod:
	$(DC_PROD) up -d

dci-prod-build:
	$(DC_PROD) build --no-cache

dci-down-prod:
	$(DC_PROD) down

dci-down-prod-clean:
	$(DC_PROD) down -v

dci-logs-prod:
	$(DC_PROD) logs -f

# ── Shell access ────────────────────────────────────────────────────────────
# These attach to an ALREADY RUNNING container, so start the service in its own
# terminal first (make dci-api / dci-web). Note they no longer need to launch the
# dev server — it is already running in that other terminal. Starting a second
# one here is what produced `EADDRINUSE :::3000`.
#
# --profile apps is required for `ps -q` to resolve a profiled service.
dci-api-shell:
	docker exec -it $$($(DC_DEV_APPS) ps -q api) sh

dci-web-shell:
	docker exec -it $$($(DC_DEV_APPS) ps -q web) sh

dci-db-shell:
	docker exec -it $$($(DC_DEV) ps -q db) sh

# ── Full reset ──────────────────────────────────────────────────────────────
dci-reset:
	$(DC_DEV_APPS) down --volumes --rmi all --remove-orphans
	docker system prune -f
