# Telco CEWAS — Churn Early Warning & Action System

An end-to-end ML + GenAI system that flags customers at risk of churning and gives the
retention agent an **evidence-backed, explained recommendation** — not just a score.

> **Status:** Phase 0 complete (infrastructure, warehouse, source data) · Phase 1 next (panel & features)

## What it does

1. **Scores** — monthly batch churn prediction (LightGBM, temporal split, PR-AUC / Recall@Top10%)
2. **Explains** — per-customer SHAP top-5 contributions, translated into plain language
3. **Retrieves** — hybrid RAG over churn reasons and campaign documents (pgvector + BM25 → RRF)
4. **Recommends** — picks from a closed action space in `dim_offer`, validated with Pydantic
5. **Evaluates** — RAGAS + LLM-as-judge against a golden set
6. **Tracks** — token cost, latency, and the action → outcome feedback loop

## Architecture

| Layer | Stack |
|---|---|
| Warehouse | PostgreSQL 16 + pgvector · `raw / core / ml / genai` schemas, star schema |
| ML | scikit-learn, LightGBM, SHAP, MLflow |
| GenAI | Claude (generation), local embeddings, hybrid RAG, guardrails, RAGAS |
| Dev | VS Code Dev Container (compose-based), uv, ruff, Makefile |

**ELT, not ETL.** CSVs land in `raw` untouched; every transformation into the star schema
is SQL running inside Postgres. Python orchestrates, it does not manipulate data. That
makes `raw` a replayable checkpoint — changing a transformation is one `telco db apply`,
not a re-ingest. (K5)

## Data

**IBM Telco Customer Churn (extended, multi-table)** — 7,043 customers of a fictional
California telecom. Public Domain.

📥 https://www.kaggle.com/datasets/datacertlaboratoria/proyecto-5-prdida-de-clientes-en-telco

The common `blastchar` version is a 21-column cut of this one. The full release carries
33+ columns, three of which this project depends on:

| Column | Role |
|---|---|
| `Offer` (None, A–E) | The LLM's closed action space |
| `ChurnCategory` / `ChurnReason` | RAG knowledge base + evaluation ground truth. ⚠️ Never model features — populated only for churned customers, so their presence reveals the label |
| `AvgMonthlyGBDownload`, `TotalRefunds`, `TotalExtraDataCharges` | Real behavioural signal |

⚠️ **Time axis.** The source is a single snapshot. `t0 = 2024-06-30` is the reference; a
6-month panel is derived from it. Tenure and charges propagate backwards
deterministically; usage metrics are **disaggregated** from real averages, not invented.
No synthetic behavioural columns exist, and the panel is tested against
`Σ monthly_charge ≈ TotalCharges`. Consequently **metrics demonstrate architectural
correctness, not production predictive performance** — K3 explains why that distinction
matters and must not be dropped when results look good.


## Documentation

- [Design decisions](docs/design-decisions.md) — the eleven choices (K1–K11) behind this
  design, including the ones that were reversed and why
- [Data model](docs/data_model.md) — layers, grain, point-in-time rule, star schema

## Layout

```
telco-cewas/
├── .devcontainer/          VS Code attaches to the compose `app` service
├── docker/                 Dockerfiles + mlflow entrypoint
├── src/telco_cewas/
│   ├── config.py           pydantic-settings — the only reader of env vars
│   ├── cli.py              `telco` — info, healthcheck, db apply/reset/ingest
│   └── db/
│       ├── core.py         Engine + schema application
│       ├── ingest.py       CSV → raw via COPY, with header validation
│       └── sql/            001 schemas · 010 raw · 020 core · 030 ml+genai
├── tests/                  `pytest -m "not integration"` runs without services
├── data/raw/               Source CSVs (git-ignored)
├── docs/                   Design decisions + data model
├── docker-compose.yml      app · postgres · mlflow (+ `genai` profile)
├── Makefile                Single command surface
└── pyproject.toml          uv groups: dev · ml · genai
```
