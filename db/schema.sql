-- Database schema. Idempotent: safe to apply on every invocation.
-- `make up` runs this automatically.
-- Layer schemas. Physical separation enforces separation of concerns:
--   raw   : verbatim copy of source CSVs, no transformation
--   core  : star schema, the single source of business truth
--   ml    : feature snapshots, model pointers, predictions
--   genai : knowledge base, embeddings, traces, eval results
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS ml;
CREATE SCHEMA IF NOT EXISTS genai;
-- pgvector: no separate vector database (ADR 0001).
-- pg_trgm: supports the lexical half of hybrid retrieval.
-- Both require superuser, which is why they live here rather than in an application-user migration.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
