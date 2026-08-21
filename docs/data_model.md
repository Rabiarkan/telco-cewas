# Data Model

Layered warehouse: five CSVs land in `raw` verbatim, SQL builds a star schema in `core`,
and `ml` / `genai` hold what the model and the RAG layer produce.

DDL lives in `src/telco_cewas/db/sql/`. See [design decisions](design-decisions.md) K1–K5
for the reasoning behind the shape.

---

## 1. Source

**IBM Telco Customer Churn**, extended multi-table release. 7,043 customers of a fictional
California telecom. Public Domain.

📥 https://www.kaggle.com/datasets/datacertlaboratoria/proyecto-5-prdida-de-clientes-en-telco

| File | Rows | Grain |
|---|---|---|
| `..._demographics.csv` | 7,043 | customer |
| `..._location.csv` | 7,043 | customer |
| `..._services.csv` | 7,043 | customer — widest table |
| `..._status.csv` | 7,043 | customer |
| `..._population.csv` | 1,671 | **ZIP code**, not customer |

Column names are PascalCase with no separators (`CustomerID`, `TenureinMonths`,
`AvgMonthlyGBDownload`). `raw` keeps them exactly; renaming happens at the `raw → core`
boundary.

### Columns that shape the design

| Column | Role |
|---|---|
| `Offer` — None, A, B, C, D, E | The LLM's closed action space |
| `ChurnCategory` (5), `ChurnReason` (21) | RAG knowledge base + evaluation ground truth |
| `AvgMonthlyGBDownload`, `AvgMonthlyLongDistanceCharges` | Real monthly averages — what makes disaggregation possible |
| `TotalRefunds`, `TotalExtraDataCharges` | Payment friction signal |
| `CustomerStatus` — Churned / Stayed / Joined | Richer than `ChurnLabel`; `Joined` matters for the panel |

### Columns dropped in `core`

| Column | Why |
|---|---|
| `Count` | Always `1` — a Cognos report artefact |
| `Country`, `State` | Single-valued (US / California) — zero information |
| `Quarter` | Constant; the extract is one quarter |
| `ChurnLabel`, `ChurnValue` | Redundant encodings of `CustomerStatus` |
| `Under30`, `SeniorCitizen`, `ReferredaFriend` | Derivable from `Age` and `NumberofReferrals` |

### ⚠️ Not present in this mirror

`SatisfactionScore`, `CLTV` and `ChurnScore` appear in some distributions of this dataset
but not this one. Do not design features around them.

### ⚠️ Forbidden as model features

`ChurnCategory` and `ChurnReason` are populated **only for churned customers**. Their
presence alone reveals the label — textbook target leakage. GenAI layer and evaluation
only. A test asserts this holds in the source.

---

## 2. Layers

| Schema | Holds | Rule |
|---|---|---|
| `raw` | Verbatim copy of the CSVs, every column `text` | No transformation, ever |
| `core` | Star schema — the single source of business truth | Conformed dimensions, documented grain |
| `ml` | Feature snapshots, model pointers, predictions | Point-in-time safe |
| `genai` | Knowledge base, embeddings, traces, eval results | Every claim traceable to a chunk |

`raw` is untyped on purpose: declaring a type is a transformation. `TotalCharges` is blank
for zero-tenure customers, which would abort the whole `COPY` against a `numeric` column.
As text the row lands and the transform decides what it means.

---

## 3. Grain

`core.fct_customer_month` — **one row per customer per month.**

```
as_of_date = t
    features  ←  data at or before t
    label     ←  churn in (t, t + 30 days]
```

One row per customer would remove the time axis, making point-in-time correctness
impossible and label leakage unavoidable. The rule is enforced by a physical `as_of_date`
column and asserted in tests.

**It follows that the split must be temporal**, never random — a random split puts the same
customer in train and test.

---

## 4. Time axis

The source is a single snapshot. `t0 = 2024-06-30`; a 6-month panel is derived backwards.

| Column class | How | Real? |
|---|---|---|
| Demographics, location, services, contract, offer | Constant across the panel → dimensions | yes |
| `tenure_months[t]` | `TenureinMonths - months_between(t, t0)` | yes, deterministic |
| `monthly_charge[t]` | Real average ± bounded noise | derived |
| `avg_monthly_gb_download[t]` | Real average ± bounded noise | derived |
| Snapshot totals | Attached to the `t0` row only | yes |
| `churn_flag_next_30d` | `1` at `t0` where `CustomerStatus = 'Churned'` | yes |

**No synthetic behavioural columns.** Spreading a real total across months is
disaggregation; inventing a series that never existed is fabrication. The first reconciles
to something in the source:

```
Σ monthly_charge[t]                              ≈ TotalCharges                (±2%)
Σ long_distance[t]                               ≈ TotalLongDistanceCharges    (±2%)
mean(avg_monthly_gb_download[t])                 ≈ AvgMonthlyGBDownload        (±1%)
tenure_months[t]                                  strictly increasing, never negative
(customer_key, date_key)                          unique
churn_flag_next_30d = 1                           only where date_key = t0
```

**⚠️ 454 customers have `CustomerStatus = 'Joined'`** with tenure 1–3 months. They get
shorter panels — rows are generated only back to their acquisition month, never clamped.
`CHECK (tenure_months >= 0)` is the database-level backstop.

**⚠️ Monthly variation is derived, not observed.** Trend features will carry little real
signal. Metrics demonstrate architectural correctness, not production predictive
performance.

---

## 5. `core` — star schema

### Dimensions

| Table | Grain | Rows |
|---|---|---|
| `dim_date` | day, 2023-01-01 → 2025-12-31 | 1,096 |
| `dim_customer` | customer | 7,044 |
| `dim_location` | ZIP code | ~1,650 |
| `dim_contract` | contract × billing × payment combination | ~24 |
| `dim_service` | distinct combination of 12 service flags | 967 |
| `dim_offer` | offer | 7 |
| `dim_churn_reason` | category × reason | 22 |

Every dimension has an **unknown member with key `-1`**, so facts can use `NOT NULL`
foreign keys when a lookup misses. Without it you either allow nullable FKs (losing join
guarantees) or drop fact rows (losing data).

Surrogate keys are generated by the database. Natural keys are carried but never referenced
by facts — if the source changes its ID format, no fact row is rewritten.

`dim_service` is a **junk dimension**: twelve low-cardinality flags collapsed into one key.
967 real combinations out of a theoretical 8,192, because the flags are not independent —
no internet means no streaming. Modelling them separately would add eleven joins and no
analytical value.

`dim_offer.discount_pct`, `cost_to_serve` and `eligibility_rule_json` are **business
parameters we define**, not source data. The CSV carries only the offer label.

### Facts

```
fct_customer_month
    PK (customer_key, date_key)
    FK customer, date, contract, service, location, offer   -- all NOT NULL

    tenure_months, monthly_charge, total_charges, total_revenue,
    total_refunds, total_extra_data_charges, total_long_distance_charges,
    avg_monthly_gb_download, avg_monthly_long_distance_charges

    customer_status, churn_flag_next_30d, as_of_date

    CHECK (tenure_months >= 0)
    CHECK (churn_flag_next_30d IN (0,1))

fct_retention_action
    action_key, customer_key, date_key, offer_key, prediction_key,
    llm_rationale, evidence_chunk_ids, agent_decision,
    accepted_flag, outcome_churn_flag, created_at
```

`fct_retention_action` closes the loop: recommendation → agent decision → outcome. Without
it the GenAI layer would produce text nobody can evaluate.

Facts resolve dimensions with `LEFT JOIN` + `COALESCE(key, -1)`.

---

## 6. `ml`

```
dim_model             mlflow_run_id, model_name, algo, trained_at, metrics_json
fct_churn_prediction  customer_key, model_key, scored_at,
                      churn_probability, risk_band, shap_top_k jsonb
                      UNIQUE (customer_key, scored_at, model_key)
feature_snapshot      PK (customer_key, as_of_date), features jsonb
```

`shap_top_k` holds the five largest contributions per customer — the bridge between the ML
layer and the GenAI layer, which turns them into plain language.

`feature_snapshot` stores exactly what the model saw. Recomputing features later is the
usual route to silent train/serve skew.

The `UNIQUE` on predictions makes re-scoring idempotent: running the job twice must not
double the rows.

---

## 7. `genai`

```
kb_document   source, doc_type, title, metadata, ingested_at
kb_chunk      doc_id, chunk_index, content,
              embedding vector(384),
              tsv tsvector GENERATED ALWAYS AS to_tsvector('english', content) STORED
llm_trace     model, input_tokens, output_tokens, latency_ms, cost_usd, cache_hit
eval_result   trace_id, metric_name, score, judge_model
```

`kb_chunk` carries **both** a dense embedding and a lexical `tsvector`, because retrieval is
hybrid — cosine similarity fused with BM25-style ranking via Reciprocal Rank Fusion. Keeping
both in one table means retrieval results join to `core` facts in a single query.

`tsv` is a generated column, so Postgres maintains it and it can never drift from `content`.

**`vector(384)`** is `BAAI/bge-small-en-v1.5` run locally. The dimension is baked into the
DDL — changing it means re-embedding the whole knowledge base.

**`llm_trace.cost_usd` is not optional instrumentation.** It is how the $10 budget is
enforced, and it must exist before the first paid call.

Indexes: HNSW on `embedding` (`vector_cosine_ops`), GIN on `tsv`.

---

## 8. Flow

```
5 CSVs
   │  telco db ingest — COPY, verbatim, header-checked
   ▼
raw.demographics · location · population · services · status
   │  telco db apply — SQL: cast, conform, load
   ▼
core.dim_* ──► core.fct_customer_month
   │  feature build, PIT-filtered on as_of_date
   ▼
ml.feature_snapshot ──► training ──► MLflow registry
   │  batch scoring
   ▼
ml.fct_churn_prediction (+ SHAP top-5)
   │  context assembly + hybrid retrieval
   ▼
genai.kb_chunk ──────► LLM ──► validated recommendation
                                      │
                                      ▼
                        core.fct_retention_action
                                      │
                                      └──► outcome feeds back into training
```

---

## 9. Open

| Question | Settled by |
|---|---|
| Panel depth: 6 months (decided) | `TenureinMonths` distribution — 2,069 customers under 12 months |
| `Joined` customers: included with short panels (decided) | 454 customers, tenure 1–3 |
