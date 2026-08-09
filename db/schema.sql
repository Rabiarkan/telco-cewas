-- Warehouse layer diagrams, separation of responsibilities
--   raw   : an exact copy of the source data; no transformations have been made
--   core  : star schema (dim_*/fct_*), single source of business logic
--   ml    : feature snapshot, model records, predictions
--   genai : knowledge base, embedding, LLM trace & eval
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS ml;
CREATE SCHEMA IF NOT EXISTS genai;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
