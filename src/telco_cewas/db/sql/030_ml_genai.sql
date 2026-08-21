-- ML predictions and the GenAI knowledge base. Both created empty.
CREATE TABLE IF NOT EXISTS ml.dim_model (
    model_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mlflow_run_id text NOT NULL UNIQUE,
    model_name text NOT NULL,
    algo text,
    trained_at timestamptz NOT NULL DEFAULT now(),
    metrics_json jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE IF NOT EXISTS ml.fct_churn_prediction (
    prediction_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_key int NOT NULL REFERENCES core.dim_customer,
    model_key int NOT NULL REFERENCES ml.dim_model,
    scored_at timestamptz NOT NULL DEFAULT now(),
    churn_probability numeric(6, 5) NOT NULL,
    risk_band text NOT NULL,
    shap_top_k jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Makes re-scoring idempotent via upsert.
    UNIQUE (customer_key, scored_at, model_key),
    CHECK (
        churn_probability BETWEEN 0 AND 1
    )
);
-- Exactly the feature values a prediction was made from. Recomputing features
-- later is the usual route to silent train/serve skew.
CREATE TABLE IF NOT EXISTS ml.feature_snapshot (
    customer_key int NOT NULL REFERENCES core.dim_customer,
    as_of_date date NOT NULL,
    features jsonb NOT NULL,
    PRIMARY KEY (customer_key, as_of_date)
);
CREATE TABLE IF NOT EXISTS genai.kb_document (
    doc_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source text NOT NULL,
    doc_type text NOT NULL,
    title text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    ingested_at timestamptz NOT NULL DEFAULT now()
);
-- Carries both a dense embedding and a lexical tsvector: retrieval is hybrid
-- (cosine + BM25, fused with RRF). vector(384) is BAAI/bge-small-en-v1.5 run
-- locally -- changing the dimension means re-embedding everything.
CREATE TABLE IF NOT EXISTS genai.kb_chunk (
    chunk_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_id bigint NOT NULL REFERENCES genai.kb_document ON DELETE CASCADE,
    chunk_index int NOT NULL,
    content text NOT NULL,
    embedding vector(384),
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    token_count int,
    UNIQUE (doc_id, chunk_index)
);
-- cost_usd is the budget enforcement mechanism, not optional instrumentation.
CREATE TABLE IF NOT EXISTS genai.llm_trace (
    trace_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_key int REFERENCES core.dim_customer,
    model text NOT NULL,
    input_tokens int NOT NULL DEFAULT 0,
    output_tokens int NOT NULL DEFAULT 0,
    latency_ms int,
    cost_usd numeric(10, 6) NOT NULL DEFAULT 0,
    cache_hit boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS genai.eval_result (
    eval_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trace_id bigint REFERENCES genai.llm_trace ON DELETE CASCADE,
    metric_name text NOT NULL,
    score numeric(6, 4),
    judge_model text,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_pred_customer ON ml.fct_churn_prediction (customer_key);
CREATE INDEX IF NOT EXISTS ix_chunk_embedding ON genai.kb_chunk USING hnsw (embedding vector_cosine_ops);
CREATE INDEX IF NOT EXISTS ix_chunk_tsv ON genai.kb_chunk USING gin (tsv);
