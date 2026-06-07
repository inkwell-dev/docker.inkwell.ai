COMPOSE_DEV  = -f .infra/compose/docker-compose.dev.yml --env-file .env
COMPOSE_PROD = -f .infra/compose/docker-compose.production.yml --env-file .env

# ── Dev ─────────────────────────────────────────────────────────────────────
dciup-dev:
	docker compose $(COMPOSE_DEV) up -d

dci-dev-build:
	docker compose $(COMPOSE_DEV) build --no-cache

dci-down:
	docker compose $(COMPOSE_DEV) down

dci-down-clean:
	docker compose $(COMPOSE_DEV) down -v

dci-logs-dev:
	docker compose $(COMPOSE_DEV) logs -f

# ── Prod ────────────────────────────────────────────────────────────────────
dciup-prod:
	docker compose $(COMPOSE_PROD) up -d

dci-prod-build:
	docker compose $(COMPOSE_PROD) build --no-cache

dci-down-prod:
	docker compose $(COMPOSE_PROD) down

dci-down-prod-clean:
	docker compose $(COMPOSE_PROD) down -v

dci-logs-prod:
	docker compose $(COMPOSE_PROD) logs -f

# ── Shell access ────────────────────────────────────────────────────────────
dci-api-shell:
	docker exec -it $$(docker compose $(COMPOSE_DEV) ps -q api) sh

dci-web-shell:
	docker exec -it $$(docker compose $(COMPOSE_DEV) ps -q web) sh

dci-db-shell:
	docker exec -it $$(docker compose $(COMPOSE_DEV) ps -q db) sh

# ── Full reset ──────────────────────────────────────────────────────────────
dci-reset:
	docker compose $(COMPOSE_DEV) down --volumes --rmi all --remove-orphans
	docker system prune -f
