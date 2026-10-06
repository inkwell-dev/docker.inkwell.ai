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
        dci-api-shell dci-web-shell dci-db-shell dci-reset dci-migrate dci-seed \
        check-submodules git-spull dci-dev-rebuild check-hosts setup-hosts \
        dciup-capture capture-seed capture capture-real

# Default target: `make` with no arguments prints this list.
.DEFAULT_GOAL := help

help:
	@echo "Dev workflow — four terminals:"
	@echo "  make dciup-dev     Terminal 0: infra only (nginx, db, redis, minio)"
	@echo "  make dci-api       Terminal 1: NestJS API, logs attached"
	@echo "  make dci-web       Terminal 2: Next.js, logs attached"
	@echo "  make dci-worker    Terminal 3: BullMQ worker, logs attached"
	@echo ""
	@echo "  make dci-migrate   Apply schema migrations (dci-api/worker do this for you)"
	@echo "  make dci-seed      Fill the dev database with a demo corpus (SEED_ARGS=... to tune)"
	@echo ""
	@echo "  make dciup-all     Everything detached (demo / onboarding)"
	@echo "  make dci-logs-dev  Follow logs of every service, app services included"
	@echo "  make dci-ps        Status of every service"
	@echo "  make dci-dev-build Rebuild dev images (after a dependency change)"
	@echo "  make dci-down      Stop the whole dev stack"
	@echo "  make setup-hosts   Add the three dev hostnames to /etc/hosts (sudo)"
	@echo ""
	@echo "  make git-spull     Pull this repo + fast-forward both submodules"
	@echo ""
	@echo "Report screenshots — the stack on the report's clock (see .infra/compose/docker-compose.capture.yml):"
	@echo "  make dciup-capture Stack up with its clock at CAPTURE_AT (default 2026-07-31 10:00:00)"
	@echo "  make capture-seed  Fresh full seed + embeddings, on that clock (REPLACES the dev data)"
	@echo "  make capture       Sitting 1: the figures that show dates, on that clock"
	@echo "  make capture-real  Sitting 2: the AI and document figures (needs the embedding quota)"
	@echo "  make dciup-all     Back to the real clock afterwards"
	@echo ""
	@echo "  http://frontend.inkwell.ai   app      (also http://localhost:8080)"
	@echo "  http://backend.inkwell.ai    API + /api/docs"
	@echo "  http://storage.inkwell.ai    MinIO S3 endpoint"
	@echo "  http://localhost:9001        MinIO console"

# ── Hostnames ───────────────────────────────────────────────────────────────
# The three dev vhosts must resolve to the nginx publish address before any of
# them work in a browser. 127.0.0.2 rather than 127.0.0.1 so port 80 cannot
# collide with anything already bound there (ddev-router, a host nginx, Apache).
HOSTS_IP    = 127.0.0.2
HOSTS_NAMES = frontend.inkwell.ai backend.inkwell.ai storage.inkwell.ai

# Warn, do not fail, and never sudo. A missing entry breaks the named hosts but
# http://localhost:8080 still serves the app, so this is not fatal — and a hard
# dependency here would make `make dciup-dev` prompt for a password.
check-hosts:
	@for n in $(HOSTS_NAMES); do \
		grep -qE "^[^#]*$(HOSTS_IP)[[:space:]].*\<$$n\>" /etc/hosts || { \
			echo "WARNING: $$n is not in /etc/hosts — run: make setup-hosts"; \
			echo "         (http://localhost:8080 works regardless)"; \
			break; \
		}; \
	done

# Appends the entry if absent. Idempotent, and the only target that needs sudo.
setup-hosts:
	@if grep -qE "^[^#]*$(HOSTS_IP)[[:space:]].*frontend.inkwell.ai" /etc/hosts; then \
		echo "/etc/hosts already has $(HOSTS_IP) entry, nothing to do"; \
	else \
		echo "$(HOSTS_IP)  $(HOSTS_NAMES)" | sudo tee -a /etc/hosts > /dev/null; \
		echo "Added: $(HOSTS_IP)  $(HOSTS_NAMES)"; \
	fi

# ── Submodules ──────────────────────────────────────────────────────────────
# The app source lives in src/ as git submodules. A clone made without
# --recurse-submodules leaves those directories EMPTY, and Docker happily
# bind-mounts an empty dir — the container then dies on a missing package.json
# with no hint as to why. Fail loudly here instead.
check-submodules:
	@for d in frontend.inkwell.ai backend.inkwell.ai; do \
		test -f src/$$d/package.json || { \
			echo "ERROR: src/$$d is empty — the app source was never checked out."; \
			echo ""; \
			echo "  make git-spull      populate both submodules (safe to re-run)"; \
			echo ""; \
			echo "Still failing with 'Repository not found'? Your default github.com"; \
			echo "identity is not a member of inkwell-dev. Check with:"; \
			echo ""; \
			echo "  ssh -T git@github.com          who git thinks you are"; \
			echo ""; \
			echo "Clone with the account that HAS access and the submodules follow it,"; \
			echo "because their URLs in .gitmodules are relative to this repo's origin."; \
			exit 1; \
		}; \
	done
	@# The spec is checked separately because it is not an app: it has no
	@# package.json, so the sentinel above would report it empty even when it is
	@# fully checked out. A ticket that changes behaviour usually has to update
	@# the spec in the same pass, so a missing checkout here is worth catching
	@# early rather than halfway through the work.
	@test -f spec.inkwell.ai/10-requirements.md || { \
		echo "ERROR: spec.inkwell.ai is empty — the specification was never checked out."; \
		echo ""; \
		echo "  make git-spull      populate every submodule (safe to re-run)"; \
		exit 1; \
	}

# Pull this repo, then fast-forward each submodule to the branch declared in
# .gitmodules (main for both). Committing the resulting pointer bump is a
# separate, deliberate step — that commit is what pins the deployable revision.
#
# The pull is conditional. `git pull origin <branch>` fails outright when the
# current branch has no counterpart on origin — a local feature branch that has
# never been pushed — and that failure used to abort the target before the two
# submodule lines ran, which are the part you actually wanted. Same story on a
# detached HEAD, where there is no branch name to pull at all.
git-spull:
	@branch=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$branch" = "HEAD" ]; then \
		echo "Detached HEAD — skipping pull, syncing submodules only."; \
	elif git ls-remote --exit-code --heads origin "$$branch" > /dev/null 2>&1; then \
		echo "Pulling origin/$$branch ..."; \
		git pull origin "$$branch"; \
	else \
		echo "Branch '$$branch' is not on origin yet — skipping pull, syncing submodules only."; \
	fi
	git submodule sync --recursive
	git submodule update --init --remote --recursive

# ── Dev ─────────────────────────────────────────────────────────────────────
# Infrastructure only: nginx, db, redis, minio. The app services are NOT started
# here — run each one in its own terminal with the targets below so you can
# restart, attach a debugger to, or read the logs of one without touching the
# others.
dciup-dev: check-hosts
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

# Apply the schema migrations and exit.
#
# Rarely needed by hand: `dci-api`, `dci-worker` and `dciup-all` all gate on the
# migrate service completing, so the normal workflow runs it for you. This
# target is for applying a NEW migration to a stack that is already up, and for
# the case the compose dependency is the thing you are debugging.
#
# `up --exit-code-from` rather than `run`: it reuses the same one-shot service
# the dependency graph gates on, so what runs here and what runs on `dci-api`
# cannot drift, and a failing migration fails this target.
dci-migrate: check-submodules
	$(DC_DEV_APPS) up --exit-code-from migrate --attach migrate --menu=false migrate

# Fill the development database with a realistic corpus: writers with distinct
# subjects, articles at four different lengths in the editor's own TipTap
# format, generated cover art and avatars in MinIO, engagement, analytics and a
# balanced credit ledger.
#
# Safe to re-run: it removes exactly the rows a previous seed created and leaves
# hand-made accounts alone.
#
#   make dci-seed
#   make dci-seed SEED_ARGS="--preset=large"     # a lot more of everything
#   make dci-seed SEED_ARGS="--fresh"            # wipe the database first
#   make dci-seed SEED_ARGS="--seed=42"          # a different, reproducible dataset
#   make dci-seed SEED_ARGS="--help"             # every flag
#
# `run --rm` rather than `exec`: the seed is a one-shot job, and running it in
# its own container means it does not need the api service to be up — only the
# database, which `make dciup-dev` already brings. `--no-deps` stops compose
# from starting api, worker and the migration alongside it.
#
# No `-e DATABASE_URL` here: the api service definition already takes it from
# .env, and passing `-e DATABASE_URL=$${DATABASE_URL}` sets it to whatever the
# calling SHELL has — which is normally nothing, and overriding it with an empty
# value is worse than not overriding it at all.
dci-seed: check-submodules
	$(DC_DEV_APPS) run --rm --no-deps api pnpm db:seed $(SEED_ARGS)

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

# ── Report capture ──────────────────────────────────────────────────────────
# The screenshots must show dates inside the report's project window, so the
# stack runs with its clock moved to CAPTURE_AT — see the header of
# docker-compose.capture.yml for why every service, the database included, has
# to move together.
#
# The offset is computed ONCE, by dciup-capture, and written to .capture-faketime.
# capture-seed and capture read it back rather than recomputing it: an offset
# recomputed minutes later would put the browser that many minutes behind the
# server, and "just now" would read as "in 12 minutes".
CAPTURE_AT ?= 2026-07-31 10:00:00
# The project's first day: no seeded date — an account's "Joined", above all —
# may fall before it.
CAPTURE_NOT_BEFORE ?= 2026-02-01
CAPTURE_OFFSET_FILE = .capture-faketime
DC_CAPTURE = CAPTURE_FAKETIME="$$(cat $(CAPTURE_OFFSET_FILE))" docker compose $(COMPOSE_DEV) \
             -f .infra/compose/docker-compose.capture.yml --profile apps

dciup-capture: check-submodules
	@echo "-$$(( $$(date +%s) - $$(date -d '$(CAPTURE_AT)' +%s) ))" > $(CAPTURE_OFFSET_FILE)
	@echo "Clock offset $$(cat $(CAPTURE_OFFSET_FILE))s — the stack will read $(CAPTURE_AT)"
	$(DC_CAPTURE) up -d --build

# The seed's dates are relative to its own clock, so it runs inside the shifted
# api container. --fresh wipes every row first, not only the previous seed's:
# the dev database collects E2E debris ("E2E: Marketplace listing 426455"),
# which a plain reseed keeps and which then appears in the feed figures.
#
# Only nadia-belhaj's articles are embedded: she is the writer the AI figures
# open, and the provider's free tier cannot embed the whole corpus in a day.
#
# The embedding backfill is the exception: it calls Gemini over HTTPS, and on a
# July clock Gemini's certificate is "not yet valid". It writes vectors, not any
# date a screen shows, so it runs with libfaketime unloaded — on the real clock,
# where certificate verification works as normal.
capture-seed: check-submodules
	@test -f $(CAPTURE_OFFSET_FILE) || { echo "run make dciup-capture first"; exit 1; }
	$(DC_CAPTURE) exec api pnpm db:seed --preset=full --fresh --not-before=$(CAPTURE_NOT_BEFORE)
	$(DC_CAPTURE) exec -e LD_PRELOAD= -e NODE_OPTIONS= api pnpm db:embed-backfill --author=nadia-belhaj

# Playwright, in its own image, on the compose network. The whole superproject
# is mounted because the capture writes into the frontend repo and the spec repo
# sits beside it; node_modules is the web container's. DRAFT_ID is re-read from
# the database, because every reseed gives the draft a new id.
CAPTURE_DRAFT_ID = $$(docker exec inkwell-db-1 psql -U inkwell -d inkwell -tAc \
  "select a.id from articles a join users u on u.id = a.author_id where u.username = 'nadia-belhaj' and a.status = 'draft' limit 1")
CAPTURE_RUN = docker build -q -t inkwell-capture-browser -f .infra/dockerfiles/capture-browser.dockerfile .infra/dockerfiles >/dev/null && \
  docker run --rm --network inkwell_inkwell --user $$(id -u):$$(id -g) --ipc=host \
  -e HOME=/tmp -e CI=1 -e DRAFT_ID=$(CAPTURE_DRAFT_ID) \
  -v "$$PWD":/w -v inkwell_web_node_modules:/w/src/frontend.inkwell.ai/node_modules:ro \
  -w /w/src/frontend.inkwell.ai

# Sitting 1: every figure that can show a date, on the report's clock. The
# browser runs on the same offset as the stack.
capture: check-submodules
	@test -f $(CAPTURE_OFFSET_FILE) || { echo "run make dciup-capture first"; exit 1; }
	$(CAPTURE_RUN) \
	  -e LD_PRELOAD=/usr/lib/faketime/libfaketime.so.1 -e FAKETIME="$$(cat $(CAPTURE_OFFSET_FILE))" \
	  -e FAKETIME_DONT_FAKE_MONOTONIC=1 -e FAKETIME_DISABLE_SHM=1 \
	  inkwell-capture-browser node_modules/.bin/playwright test --config capture/playwright.capture.ts \
	  --grep-invert @real-clock $(CAPTURE_ARGS)

# Sitting 2: the AI and document figures, tagged @real-clock. The providers'
# certificates postdate the report's clock, so the api and the worker run on the
# real clock for this sitting (docker-compose.capture-ai.yml); the database, the
# web app and the browser stay on the report's. Needs the embedding quota: the
# full backfill of nadia-belhaj's articles runs first.
#
# Portfolio Insights stamp generatedAt from the api's (real) clock, so the
# insights generated here are re-dated to the database's clock, and only then is
# the evaluation page photographed — on the report's clock, like sitting 1.
DC_CAPTURE_AI = $(DC_CAPTURE) -f .infra/compose/docker-compose.capture-ai.yml

capture-real: check-submodules
	@test -f $(CAPTURE_OFFSET_FILE) || { echo "run make dciup-capture first"; exit 1; }
	$(DC_CAPTURE_AI) up -d api worker
	$(DC_CAPTURE_AI) exec api pnpm db:embed-backfill --author=nadia-belhaj
	$(CAPTURE_RUN) \
	  -e LD_PRELOAD=/usr/lib/faketime/libfaketime.so.1 -e FAKETIME="$$(cat $(CAPTURE_OFFSET_FILE))" \
	  -e FAKETIME_DONT_FAKE_MONOTONIC=1 -e FAKETIME_DISABLE_SHM=1 \
	  inkwell-capture-browser node_modules/.bin/playwright test --config capture/playwright.capture.ts \
	  --grep @real-clock $(CAPTURE_ARGS)
	docker exec inkwell-db-1 psql -U inkwell -d inkwell -c \
	  "update portfolio_insights set generated_at = now(), expires_at = now() + (expires_at - generated_at)"
	$(DC_CAPTURE) up -d api worker
	$(MAKE) capture CAPTURE_ARGS="--grep 'a writer evaluation'"

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
