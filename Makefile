# Single command surface. Works identically inside the dev container and from the host.
SHELL := /bin/bash
PROJECT := telco-cewas
COMPOSE := docker compose
UV := uv

.DEFAULT_GOAL := help
.PHONY: help setup sync ml sync-ml sync-genai up down restart ps logs logs-mlflow \
        shell db db-ready db-apply db-status db-reset ingest genai-up genai-down \
        lint fmt test check lock lock-check \
        verify clean nuke

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------ environment
setup: ## First-time setup: base + dev dependencies + git hooks
	$(UV) sync --group dev
	# No '|| true' here: if pre-commit cannot be installed, setup should fail
	# loudly. Step 8 of `make verify` treats this hook as mandatory.
	$(UV) run pre-commit install
	@echo "✅ setup complete. Run 'make up' to start the services."

sync: ## Sync base + dev dependencies
	$(UV) sync --group dev

sync-ml: ml ## Alias for `make ml`

ml: ## ML dependencies + register the notebook kernel
	$(UV) sync --group ml
	$(UV) run python -m ipykernel install --user \
		--name telco-cewas --display-name "Telco CEWAS (ml)"
	@echo "✅ Kernel registered. Open a .ipynb and pick 'Telco CEWAS (ml)'."

sync-genai: ## GenAI dependencies (LLM client, pgvector, fastapi)
	$(UV) sync --group genai

# --------------------------------------------------------------------- services
up: ## Start services and apply the schema
	$(COMPOSE) up -d postgres mlflow
	@until pg_isready -q 2>/dev/null; do sleep 1; done
	@$(UV) run telco db apply
	@$(MAKE) --no-print-directory ps

db-apply: ## Apply db/sql/*.sql (idempotent, safe any time)
	$(UV) run telco db apply

db-status: ## List SQL files and existing tables
	$(UV) run telco db status

db-reset: ## DROP project schemas and rebuild (asks for confirmation)
	$(UV) run telco db reset

ingest: ## Load the source CSVs into raw.* (idempotent)
	$(UV) run telco db ingest

down: ## Stop data services (leaves the app container alone)
	$(COMPOSE) stop postgres mlflow api 2>/dev/null || true
	@echo "ℹ️  'app' left running so the dev container connection survives."

restart: down up ## Restart the data services

ps: ## Service status
	@$(COMPOSE) ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}"

logs: ## Follow all logs
	$(COMPOSE) logs -f --tail=100

logs-mlflow: ## Follow mlflow logs only
	$(COMPOSE) logs -f --tail=100 mlflow

genai-up: ## Start the genai profile (api on :8080)
	$(COMPOSE) --profile genai up -d api

genai-down: ## Stop the genai profile
	$(COMPOSE) --profile genai stop api

# ----------------------------------------------------------------------- access
shell: ## Open a bash shell in the app container
	$(COMPOSE) exec app bash

db: ## psql session (PG* variables are already set)
	psql

db-ready: ## Postgres health check
	@pg_isready && echo "✅ postgres ready"

# ---------------------------------------------------------------------- quality
lint: ## ruff check
	$(UV) run ruff check .

fmt: ## ruff format + import fixes
	$(UV) run ruff format .
	$(UV) run ruff check --fix .

test: ## pytest
	$(UV) run pytest -q

lock: ## Re-resolve the lock file (after editing pyproject)
	$(UV) lock

lock-check: ## Is the lock file current? (CI gate)
	$(UV) lock --check

check: lock-check lint test ## Same gate as CI

verify: ## Run the full acceptance suite
	@echo "── 1/9 services ────────────────────────────────"
	@$(COMPOSE) ps --format "{{.Service}}: {{.Status}}"
	@echo "── 2/9 DooD (sibling container access) ─────────"
	@docker ps -q >/dev/null && echo "  ✅ docker socket is accessible"
	@echo "── 3/9 postgres schemas ────────────────────────"
	@psql -tAc "SELECT string_agg(schema_name, ', ' ORDER BY schema_name) \
	  FROM information_schema.schemata \
	  WHERE schema_name IN ('raw','core','ml','genai')" \
	  | grep -q "core, genai, ml, raw" \
	  && echo "  ✅ raw, core, ml, genai" \
	  || (echo "  ❌ missing schemas -> telco db apply"; exit 1)
	@echo "── 4/9 extensions ──────────────────────────────"
	@psql -tAc "SELECT string_agg(extname, ', ' ORDER BY extname) \
	  FROM pg_extension WHERE extname IN ('vector','pg_trgm')" \
	  | grep -q "pg_trgm, vector" \
	  && echo "  ✅ vector, pg_trgm" \
	  || (echo "  ❌ missing extensions -> telco db apply"; exit 1)
	@echo "── 5/9 mlflow backend database ─────────────────"
	@psql -tAc "SELECT 1 FROM pg_database WHERE datname='mlflow'" | grep -q 1 \
	  && echo "  ✅ mlflow database exists" || (echo "  ❌ missing"; exit 1)
	@echo "── 6/9 mlflow http ─────────────────────────────"
	@curl -fsS http://mlflow:5000/health >/dev/null \
	  && echo "  ✅ http://mlflow:5000/health" || (echo "  ❌ unreachable"; exit 1)
	@echo "── 7/9 app config + connection ─────────────────"
	@$(UV) run telco healthcheck
	@echo "── 8/9 pre-commit hook ─────────────────────────"
	@test -x .git/hooks/pre-commit \
	  && echo "  ✅ hook installed" \
	  || (echo "  ❌ not installed -> make setup"; exit 1)
	@echo "── 9/9 lint + test ─────────────────────────────"
	@$(UV) run ruff check . && echo "  ✅ ruff clean"
	@$(UV) run pytest -q
	@echo ""
	@echo "🎉 Phase 0 acceptance criteria pass."

# ---------------------------------------------------------------------- cleanup
clean: ## Remove caches and build artifacts
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf .pytest_cache .ruff_cache

nuke: ## LAST RESORT: delete postgres + mlflow data (try `make up` first)
	@echo "⚠️  pgdata and mlartifacts will be DELETED. All DB rows and MLflow runs are lost."
	@read -p "Continue? [yes/N] " a; [ "$$a" = "yes" ] || (echo "aborted."; exit 1)
	# Deliberately NOT `down -v`: that would also remove the 'app' container you
	# are sitting in and drop the dev container connection.
	$(COMPOSE) rm -sfv postgres mlflow
	-docker volume rm $(PROJECT)_pgdata $(PROJECT)_mlartifacts
	@echo "✅ Clean. Run 'make up' to rebuild."
