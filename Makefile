SHELL := /bin/bash
COMPOSE := docker compose
UV := uv

.DEFAULT_GOAL := help
.PHONY: help setup sync ml sync-ml sync-genai up down restart ps logs logs-mlflow \
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

down: ## Stop all services (data is preserved)
	$(COMPOSE) --profile genai down

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

shell: ## app container bash
	$(COMPOSE) exec app bash

db: ## psql (PG* env ready)
	psql

db-ready: ## Postgres status
	@pg_isready && echo "✅ Postgres is ready." || echo "❌ Postgres is not ready."

# quality
lint: ## ruff check
	$(UV) run ruff check .

fmt: ## ruff format + import fix
	$(UV) run ruff format .
	$(UV) run ruff check --fix .

test: ## pytest
	$(UV) run pytest -q

check: lint test

clean: ## Clean Cache/artifact 
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	rm -rf .pytest_cache .ruff_cache

nuke: ## WARNING: This will also delete the volumes (pgdata, mlartifacts)
	$(COMPOSE) --profile genai down -v