# Design Decisions

12 choices that shaped this project, and why. Several were reversed during
development — the original and the reason for the change are kept, because *why* a
decision changed carries as much information as the decision itself.


| # | Decision |
|---|---|
| [K1](#k1) | Single Postgres, four schemas, pgvector |
| [K2](#k2) | Dataset: the extended IBM release 🔄 |
| [K3](#k3) | Grain is customer × month, and nothing is fabricated 🔄 |
| [K4](#k4) | The LLM picks from a closed set |
| [K5](#k5) | ELT: transform in the database, and `raw` is untyped |
| [K6](#k6) | Idempotent SQL scripts instead of migrations 🔄 |
| [K7](#k7) | Dev container: compose, sibling Docker, layered dependencies |
| [K8](#k8) | Notebooks run on the dev container's own kernel 🔄 |
| [K9](#k9) | One definition per setting 🔄 |
| [K10](#k10) | Embeddings run locally at 384 dimensions 🔄 |
| [K11](#k11) | A hard $10 budget, enforced in code |

- 🔄 marks a revised decision.
---

## K1 — Single Postgres, four schemas, pgvector

One `pgvector/pgvector:pg16` instance holds `raw`, `core`, `ml` and `genai`. No separate
warehouse, no dedicated vector database.

The deciding argument: a recommendation needs retrieved chunks **and** the customer's
history **and** their eligible offers. In one database that is a single SQL statement. With
a separate vector store it is two round trips and a join assembled in application code.

Physical schema separation also enforces separation of concerns — `raw` is an untouched
copy, `core` is the single source of business truth, `ml` holds model output, `genai` holds
the knowledge base.

**Cost accepted:** pgvector becomes a bottleneck at millions of vectors. Expected scale is
under 100K chunks. Retrieval sits behind a `VectorStore` protocol, so switching is one
adapter.

---

## K2 — Dataset: the extended IBM release 🔄

**Was:** the common `blastchar` Telco Churn set (21 columns).
**Now:** IBM's original multi-table release (33+ columns).

The trimmed set was missing everything the GenAI layer needed. The full release has it:

| Need | Column |
|---|---|
| The LLM's action space | `Offer` (None, A–E) — plus who received which |
| RAG content and evaluation ground truth | `ChurnCategory`, `ChurnReason` |
| Real behavioural signal | `AvgMonthlyGBDownload`, `TotalRefunds`, `TotalExtraDataCharges` |

**⚠️ Two corrections made after actually looking at the data.**

`SatisfactionScore`, `CLTV` and `ChurnScore` are *not* in this mirror. Do not design features around them.

And the observed churn rate per offer is **not** a causal effect. Offer E shows 52.9% churn
against a 26.5% baseline; Offer A shows 6.7%. Offers were not randomly assigned — E most
likely went to customers already judged at risk. These rates are context, never "Offer A works best".

**⚠️ Hard rule:** `ChurnCategory` and `ChurnReason` are filled only for churned customers.
Their presence alone reveals the label, so they are forbidden as model features. GenAI and
evaluation only.

---

## K3 — Grain is customer × month, and nothing is fabricated 🔄

`core.fct_customer_month` holds one row per customer per month, with a physical
`as_of_date` column.

One row per customer would remove the time axis, which makes point-in-time correctness
impossible and label leakage unavoidable.

**The rule:** for `as_of_date = t`, features come from data at or before `t`; the label
comes from churn in `(t, t+30d]`. It follows that the train/test split must be temporal —
a random split puts the same customer on both sides.

**Was:** invent monthly usage series conditioned on the churn label.
**Now:** no synthetic behavioural columns at all.

Synthetic columns derived from the label make *us* the source of the leakage — the
resulting metric measures how hard we pushed, not how well the model predicts. The extended
dataset (K2) removed most of the need anyway.

What we do instead is **disaggregation**: spreading a real total across months is a
distributional assumption about data that exists. Inventing a series that never existed is
not. The first reconciles to a source aggregate; the second reconciles to nothing.

```
Σ monthly_charge[t] ≈ TotalCharges
AvgMonthlyLongDistanceCharges × TenureinMonths ≈ TotalLongDistanceCharges
```

**⚠️ Stated plainly:** monthly variation is derived, not observed. Trend features will
carry little real signal, and **metrics demonstrate architectural correctness, not
production predictive performance.** This must not be quietly dropped when the numbers
look good.

---

## K4 — The LLM picks from a closed set

The model never writes an offer. It selects an `offer_id` from `core.dim_offer`; the output
is validated with Pydantic and rejected if the id does not exist. Eligibility rules run
*before* the LLM, narrowing the candidates.

Two things follow. A hallucinated campaign can never reach a customer. And the loop
recommendation → agent decision → outcome closes through `core.fct_retention_action` —
free text has nothing to join on.

---

## K5 — ELT: transform in the database, and `raw` is untyped

CSVs load into `raw` verbatim, then SQL transforms them into `core`. Python orchestrates —
reads files, calls `COPY`, runs SQL — but does not touch the data.

**Why this order.** `raw` becomes a replayable checkpoint. Changing a transformation means
re-running SQL against data already in the database; under ETL it means re-parsing the CSVs,
because the only untransformed copy sits on disk in a format the database cannot query.
Transformation logic changes constantly early on, and that loop is the difference between
iterating in seconds and in minutes.

**Every `raw` column is `text`,** which is the same decision seen from the other side.
Declaring a type *is* a transformation. The known defect in this dataset is `TotalCharges`
being blank for zero-tenure customers: against a `numeric` column that aborts the entire
`COPY`. As text the row lands, validation reports it, and the transform decides what it
means. A `COPY` error gives you a byte offset; a cast failure in SQL can tell you "3
customers have blank TotalCharges, all with tenure 0" — a finding rather than an incident.

**Cost accepted:** SQL is not self-verifying, so the transforms need tests. Casting must be
explicit and handle failure — which is exactly where the business rule belongs.

---

## K6 — Idempotent SQL scripts instead of migrations 🔄

**Was:** `db/init/` via Postgres's `docker-entrypoint-initdb.d`, then a plan for a full
migration framework with a ledger and checksums.
**Now:** numbered SQL files in `db/sql/`, all applied on every run.

The first version broke in a way worth remembering: `docker-entrypoint-initdb.d` runs only
when the data directory is empty and is skipped **silently** otherwise. Schema state
depended on the volume's history rather than on the repository, and MLflow spent 90 seconds
retrying against a database that had never been created.

The fix generalised into a principle: **a setup step that runs once is fragile; one that
runs always and is harmless is robust.** `CREATE SCHEMA IF NOT EXISTS` is safe every time,
so run it every time and delete the question "did this run?" from existence.

That same principle removed the need for a migration framework. A ledger exists to answer
"has this file run before?" — idempotency makes the question meaningless. The problems
Flyway and Alembic solve (several developers, unrecreatable production data, zero-downtime
deploys) are not present here, and the whole warehouse rebuilds from five CSVs in under a
minute.

**⚠️ The real limit:** idempotent DDL creates but cannot *alter*. Changing a column type is
not expressible — the table exists, the statement is skipped, the change never lands.
Recovery is `telco db reset`, acceptable only because the source is five files.

---

## K7 — Dev container: compose, sibling Docker, layered dependencies

Three choices that together define the development environment.

**The dev container is a compose service.** It attaches to `app` in `docker-compose.yml`
rather than defining its own image, so development and runtime share one network and one
DNS namespace. From the shell you reach `postgres` and `mlflow` by the same names the
Python code uses.

**Docker-outside-of-Docker, not DinD.** The host socket is mounted, so compose services are
siblings. DinD needs a second daemon and `privileged: true` — heavier, and the sibling view
is the honest one: `docker compose ps` shows the same stack inside and outside.

**Dependencies are layered:** `base` + `dev` + `ml` + `genai`. A Codespace start pulls only
`dev`; ~400MB of ML libraries never touch disk until `make ml`.

**⚠️ Security concession, taken knowingly.** The DooD feature's socat proxy needs `sudo`,
so `vscode` has `NOPASSWD:ALL`. That plus host socket access makes the container user
effectively root on the host. Fine for an ephemeral dev environment; neither will exist in
a production image.

**One detail worth keeping:** the virtualenv lives at `/opt/venv`, outside the bind mount.
Inside it, every file operation crosses to the host filesystem and `uv sync` runs several
times slower.

---

## K8 — Notebooks run on the dev container's own kernel 🔄

**Was:** a JupyterLab service on port 8888 under an `ml` compose profile.
**Now:** `ipykernel` in the dev container's venv, using VS Code's notebook editor.

A separate container would have its own `/opt/venv` (see K7). The two drift independently
and produce the costliest failure in ML work: code that trains correctly in a notebook and
behaves differently from the CLI. In a system that produces models, that means silently
producing a *different model*.

Side benefits: the debugger works inside cells, ruff lints `.ipynb` natively, and an idle
container disappears.

**The principle this produced:** a compose profile is for a long-lived service. ML
exploration is a development activity. The `genai` profile survives because the API
genuinely is a service.

**⚠️** The kernel registration lives in the container home directory and is lost on
rebuild. `make ml` is idempotent; re-run it.

---

## K9 — One definition per setting 🔄

Every configuration value is defined once; everything else reads from there. No module
touches `os.environ` — `Settings` (pydantic-settings) is the only reader, which turns
configuration into a contract: a missing or mistyped value fails at startup instead of
surfacing as `None` three layers down.

This became a rule after three separate failures with one shared cause:

| Conflicting pair | Symptom |
|---|---|
| `db/init` + `make bootstrap` | Schema never created — the gap between them |
| pre-commit's pinned ruff + `pyproject.toml`'s ruff | Formatter ping-pong; commits never passed |
| Manual socket mount + the DooD feature's own mount | Permission denied |

**Why this class of bug is nasty:** both sides behave correctly in isolation and neither
raises an error. The failure lives in the gap, which is where nobody looks.

Current applications: ruff version → `pyproject.toml` only. Schema → `db/sql/` only.
Environment variables → the compose `x-app-env` anchor, and `Settings` in code. Even the
ingest layer reads its expected columns from `information_schema` rather than a second
hardcoded list.

---

## K10 — Embeddings run locally at 384 dimensions 🔄

**Was:** OpenAI `text-embedding-3-small` at 1024 dimensions.
**Now:** `BAAI/bge-small-en-v1.5` through `fastembed`, 384 dimensions, in-process.

Profiling the source found only **21 distinct `ChurnReason` texts**. Embedding-model quality
differences show up at scale, where near-duplicates must be separated; over a corpus this
small the gap is minor, and hybrid retrieval absorbs more of it. Against that, the hosted
option needed a second account, a second key, a second spend limit and a second bill — for
about four cents of embedding.

A benefit that only appeared afterwards: with no API key, **evaluation runs in CI
unconditionally**. Otherwise regression tests would need secrets or fixtures — and tests
that cost money per commit get disabled.

**⚠️ Stated plainly:** 384 dimensions carry less information than 1024, so retrieval is
measurably weaker. If context precision proves inadequate, the fallback is the hosted model
at the cost of re-embedding.

**⚠️ Same model on both sides.** Document and query vectors must come from the same model at
the same dimension, or cosine similarity compares unrelated spaces and returns confident
nonsense. The model is pinned in `Settings`, never passed per call.

---

## K11 — A hard $10 budget, enforced in code

Total spend must not exceed $10. Since embeddings run locally (K10), Claude generation is
the only paid call and the whole ceiling belongs to it.

A README note would not have worked. The realistic failure is not steady-state spend but a
retry loop, an accidental re-embed, or an evaluation sweep that runs 500 times instead of
50 — none of which good intentions prevent.

| Level | Mechanism | Why it exists |
|---|---|---|
| 1 | Anthropic console spend limit, auto-reload off | The only layer a bug in our code cannot bypass |
| 2 | `cost_usd` on every `genai.llm_trace` row | A number nobody can see is a number nobody controls |
| 3 | A guard raising before each paid call | Stops the job; a job that stops is recoverable |

Because the ceiling is low, prompt caching, the Batch API, model routing and a semantic
cache stop being optimisations and become requirements. Cost per recommendation ends up
reported alongside PR-AUC and faithfulness — an LLM feature whose unit economics are
unknown is not shippable.
