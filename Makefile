SHELL := /bin/bash
COMPOSE := docker compose
UV := uv

.DEFAULT_GOAL := help
.PHONY: help setup sync ml sync-ml sync-genai up down restart ps logs logs-mlflow verify lock lock-check \
        shell db db-ready genai-up genai-down lint fmt test check clean nuke

help:
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# environment
setup: ## Initial setup (postCreateCommand): base + dev dependencies
	$(UV) sync --group dev
	$(UV) run pre-commit install || true
	@echo "✅ setup done. Start the services with 'make up'."

sync: ## Base + Synchronize major dependencies
	$(UV) sync --group dev

sync-ml: ml ## sync-ml -> ml

ml: ## ML dependencies + save the notebook kernel
	$(UV) sync --group ml
	$(UV) run python -m ipykernel install --user \
		--name telco-cewas --display-name "Telco CEWAS (ml)"
	@echo "✅ The notebook kernel is ready. Open the .ipynb file in VS Code -> kernel: 'Telco CEWAS (ml)'"

sync-genai: ## Add GenAI dependencies (llm client, pgvector, fastapi)
	$(UV) sync --group genai

# services
up: ## core stack: postgres + mlflow
	$(COMPOSE) up -d postgres mlflow
	@$(MAKE) --no-print-directory ps

down: ## Stop all services (data is preserved, dont close app service)
	$(COMPOSE) stop postgres mlflow api 2>/dev/null || true
	@echo "ℹ️  'app' running -- dev container conn is maintained."

restart: down up ## Restart the kernel stack

ps: ## Service Status
	@$(COMPOSE) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"

logs: ## Follow all logs
	$(COMPOSE) logs -f --tail=100

logs-mlflow: ## mlflow logs
	$(COMPOSE) logs -f --tail=100 mlflow

genai-up: ## Open Profile 'genai' (api :8080)
	$(COMPOSE) --profile genai up -d api

genai-down: ## Close Profile 'genai'
	$(COMPOSE) --profile genai stop api

# access
shell: ## app container bash
	$(COMPOSE) exec app bash

db: ## psql (PG* env ready)
	psql

db-ready: ## Postgres status
	@pg_isready && echo "✅ Postgres is ready." || echo "❌ Postgres is not ready."

# quality - ruff
lint: ## ruff check
	$(UV) run ruff check .

fmt: ## ruff format + import fix
	$(UV) run ruff format .
	$(UV) run ruff check --fix .

test: ## pytest
	$(UV) run pytest -q

check: lock-check lint test

lock: ## Re-unlock the file (when the pyproject changes)
	$(UV) lock

lock-check: ## Is the lock up to date? (CI)
	$(UV) lock --check

# ------ verify -------
verify: ## Phase 0 eligibility criteria
	@echo "── 1/8 services ────────────────────────────────"
	@$(COMPOSE) ps --format "{{.Service}}: {{.Status}}"
	@echo "── 2/8 DooD (sibling container access) ─────────"
	@docker ps -q >/dev/null && echo "  ✅ docker socket is accessible"
	@echo "── 3/8 postgres schemas ───────────────────────"
	@psql -tAc "SELECT string_agg(schema_name, ', ' ORDER BY schema_name) \
	  FROM information_schema.schemata \
	  WHERE schema_name IN ('raw','core','ml','genai')" \
	  | grep -q "core, genai, ml, raw" \
	  && echo "  ✅ raw, core, ml, genai" \
	  || (echo "  ❌ missing schemas -> make nuke && make up"; exit 1)
	@echo "── 4/8 extensions ───────────────────────────"
	@psql -tAc "SELECT string_agg(extname, ', ' ORDER BY extname) \
	  FROM pg_extension WHERE extname IN ('vector','pg_trgm')" \
	  | grep -q "pg_trgm, vector" \
	  && echo "  ✅ vector, pg_trgm" \
	  || (echo "  ❌ missing extension -> make nuke && make up"; exit 1)
	@echo "── 5/8 mlflow backend database ─────────────────"
	@psql -tAc "SELECT 1 FROM pg_database WHERE datname='mlflow'" | grep -q 1 \
	  && echo "  ✅ mlflow database exist" || (echo "  ❌ missing"; exit 1)
	@echo "── 6/8 mlflow http ─────────────────────────────"
	@curl -fsS http://mlflow:5000/health >/dev/null \
	  && echo "  ✅ http://mlflow:5000/health" || (echo "  ❌ unreachable"; exit 1)
	@echo "── 7/8 app config + connection ──────────────"
	@$(UV) run telco healthcheck
	@echo "── 8/8 lint + test ─────────────────────────────"
	@$(UV) run ruff check . && echo "  ✅ ruff clean"
	@$(UV) run pytest -q
	@echo ""
	@echo "🎉 Phase 0 Acceptance Criteria is done."

# ------ verify -------

clean: ## Clean Cache/artifact
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf .pytest_cache .ruff_cache

nuke: ## WARNING: This will also delete the volumes (pgdata, mlartifacts)
# delete only data services..
	$(COMPOSE) --profile genai down -v
	@echo "⚠️  pgdata ve mlartifacts will be deleted. All DB records and MLflow runs will be deleted."
	@read -p "Continue? [yes/N] " ans; [ "$$ans" = "yes" ] || (echo "Exit."; exit 1)
	$(COMPOSE) rm -sfv postgres mlflow
	-docker volume rm $(PROJECT)_pgdata $(PROJECT)_mlartifacts
	@echo "✅ Cleaned. 'make up' will work again."
# DO NOT use 'down -v': because it also removes the ‘app’ container, which breaks the dev container connection.
