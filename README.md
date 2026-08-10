# 📡 TELCO CEWAS — Churn Early Warning & Action System

An end-to-end ML + GenAI system that flags customers at risk of churning and gives
the retention agent an **evidence-backed, explained recommendation** — not just a score.

> **Status:** Phase 0 complete (infrastructure) · Phase 2 starting (data model)

## What it does

1. **Scores** — monthly batch churn prediction (LightGBM, temporal split, PR-AUC / Recall@Top10%)
2. **Explains** — per-customer SHAP top-5 contributions, translated into plain language
3. **Retrieves** — hybrid RAG over churn reasons and campaign documents (pgvector + BM25 → RRF)
4. **Recommends** — picks from a closed action space in `dim_offer`, validated with Pydantic
5. **Evaluates** — RAGAS + LLM-as-judge, regression-tested against a golden set
6. **Tracks** — token cost, p95 latency, and the action → outcome feedback loop


## Architecture

| Layer | Stack |
|---|---|
| Warehouse | PostgreSQL 16 + pgvector · `raw / core / ml / genai` schemas, star schema |
| ML | scikit-learn, LightGBM, SHAP, MLflow (tracking + registry) |
| GenAI | Hybrid RAG, structured output, guardrails, RAGAS |
| Dev | VS Code Dev Container (compose-based), uv, ruff, Makefile |



## Data

**IBM Telco Customer Churn (extended, multi-table)** — 7,043 customers of a fictional
California telecom company. License: Public Domain.

📥 https://www.kaggle.com/datasets/datacertlaboratoria/proyecto-5-prdida-de-clientes-en-telco

The widely used `blastchar` version is a trimmed cut of this one (21 columns). The full
release carries 33+ columns, including three that this project depends on:

- `offer` — offers previously extended to each customer (None, A–E) → the LLM's closed action space
- `churn_category` / `churn_reason` — RAG knowledge base and evaluation ground truth
- `satisfaction_score`, `avg_monthly_gb_download`, `total_refunds`, `cltv` — real behavioural signals

⚠️ **A note on the time axis.** The source is a single snapshot. We treat
`t0 = 2024-06-30` as the reference point and derive a 6-month panel from it. Tenure and
charges are propagated backwards deterministically; usage metrics are **disaggregated**
from real averages across months rather than invented. No synthetic behavioural columns
exist. Panel generation is tested against invariants such as
`Σ monthly_charges ≈ total_charges`. See [`docs/data_model.md`](docs/data_model.md).


## Documentation
- [Roadmap](docs/roadmap/phase-0.md) — milestones, definitions of done, task status
- [Design decisions](docs/design-decisions.md) — K1–K, including why some were revised
- [Data model](docs/data_model.md) — grain, point-in-time rule, star schema
- [ADRs](docs/adr/) — deep dives on individual architectural decisions



## Project layout

```
telco-cewas/
│
├── .devcontainer/
│   └── devcontainer.json          Attaches VS Code to the compose `app` service
│
├── docker/
│   ├── Dockerfile.app             python:3.12-slim + uv + non-root user
│   ├── Dockerfile.mlflow          mlflow + psycopg2 (official image lacks it)
│   └── entrypoint.mlflow.sh       Waits for postgres, creates its own backend DB
│
├── db/
│   ├── schema.sql                 Schemas + extensions — idempotent, applied by `make up`
│   └── migrations/                Ordered, checksummed DDL
│
├── src/telco_cewas/
│   ├── config.py                  pydantic-settings — the only reader of env vars
│   ├── cli.py                     `telco` entrypoint (info, healthcheck, …)
│   ├── db/                        Engine, repositories, migration runner
│   ├── data/                      Ingest, panel builder, quality assertions
│   ├── features/                  Point-in-time safe feature construction
│   ├── ml/                        train · evaluate · score · explain
│   ├── genai/                     embed · retrieve · prompts · guardrails
│   └── api/                       FastAPI routes and schemas
│
├── docs/
│   ├── design-decisions.md        K1–K with rationale and revisions
│   ├── data_model.md              Grain, PIT rule, star schema
│   ├── adr/                       One file per architectural decision
│   └── roadmap/                   Phase plans with definitions of done
│
├── tests/                         Acceptance + data quality (`-m integration`)
├── notebooks/                     Exploration — production code lives in src/
├── evals/                         Golden set and judge rubrics
├── data/raw/                      Source CSVs (git-ignored)
│
├── docker-compose.yml             app · postgres · mlflow (+ `genai` profile)
├── Makefile                       Single command surface — `make help`
├── pyproject.toml                 uv dependency groups: dev · ml · genai
└── uv.lock                        Pinned resolution — committed on purpose
```
