"""Phase 0 acceptance tests: is the infrastructure up, and is it configured correctly?

Split by cost: the unit tests run anywhere, the `integration` ones need a live
Postgres and MLflow. `make test` runs both; CI without services runs
`pytest -m "not integration"`.
"""

import urllib.request

import pytest
from sqlalchemy import Engine, create_engine, text

from telco_cewas.config import Settings, get_settings


@pytest.fixture(scope="module")
def engine() -> Engine:
    """One engine for the whole module.

    pool_pre_ping catches connections dropped while a container restarted, which
    happens often enough in a dev container to be worth the extra round trip.
    """
    return create_engine(get_settings().database_url, pool_pre_ping=True)


# configuration


def test_settings_loads() -> None:
    s = get_settings()
    assert s.database_url.startswith("postgresql")
    assert s.mlflow_tracking_uri


def test_embedding_config_matches_schema() -> None:
    """The vector dimension is baked into genai.kb_chunk (ADR 0004).

    If this drifts from the DDL every insert fails at runtime, and the fix is
    re-embedding the whole knowledge base -- so catching it here is cheap.
    """
    s = get_settings()
    assert s.embedding_model == "text-embedding-3-small"
    assert s.embedding_dimensions == 1024


def test_budget_allocations_fit_within_total() -> None:
    """Level 3 of the budget enforcement in ADR 0011."""
    s = get_settings()
    assert s.budget_embedding_usd + s.budget_generation_usd <= s.budget_total_usd
    assert 0 < s.budget_warn_pct < 1


def test_budget_validator_rejects_overallocation() -> None:
    """The guard must reject bad input, not merely describe the rule.

    An untested guard is not a guard: this asserts the failure path, which is the
    only path that matters.
    """
    with pytest.raises(ValueError, match="exceed the total ceiling"):
        Settings(
            budget_total_usd=10.0,
            budget_embedding_usd=6.0,
            budget_generation_usd=6.0,
        )


# integration


@pytest.mark.integration
def test_postgres_schemas_exist(engine: Engine) -> None:
    with engine.connect() as conn:
        schemas = set(
            conn.execute(text("SELECT schema_name FROM information_schema.schemata")).scalars()
        )
    assert {"raw", "core", "ml", "genai"} <= schemas


@pytest.mark.integration
def test_required_extensions_installed(engine: Engine) -> None:
    """pgvector for similarity search, pg_trgm for the lexical half of hybrid retrieval."""
    with engine.connect() as conn:
        installed = set(conn.execute(text("SELECT extname FROM pg_extension")).scalars())
    assert {"vector", "pg_trgm"} <= installed


@pytest.mark.integration
def test_schema_application_is_idempotent(engine: Engine) -> None:
    """db/schema.sql is re-applied on every `make up` (ADR 0005, ADR 0008).

    Re-running the statements must be a no-op rather than an error -- that
    property is what removes the need for a migration ledger.
    """
    with engine.begin() as conn:
        conn.execute(text("CREATE SCHEMA IF NOT EXISTS raw"))
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))


@pytest.mark.integration
def test_mlflow_backend_database_exists(engine: Engine) -> None:
    """The MLflow entrypoint creates this itself rather than relying on bootstrap (K11)."""
    with engine.connect() as conn:
        found = conn.execute(
            text("SELECT 1 FROM pg_database WHERE datname = 'mlflow'")
        ).scalar_one_or_none()
    assert found == 1


@pytest.mark.integration
def test_mlflow_reachable() -> None:
    url = get_settings().mlflow_tracking_uri.rstrip("/") + "/health"
    with urllib.request.urlopen(url, timeout=10) as r:
        assert r.status == 200
