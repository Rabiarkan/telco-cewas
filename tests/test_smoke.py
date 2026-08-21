"""Infrastructure and configuration."""

import urllib.request

import pytest
from sqlalchemy import Engine, text

from telco_cewas.config import Settings, get_settings
from telco_cewas.db import get_engine


@pytest.fixture(scope="module")
def engine() -> Engine:
    return get_engine()


def test_settings_loads() -> None:
    s = get_settings()
    assert s.database_url.startswith("postgresql")
    assert s.embedding_dimensions == 384
    assert s.budget_generation_usd <= s.budget_total_usd


def test_budget_validator_rejects_overallocation() -> None:
    """An untested guard is not a guard: assert the failure path."""
    with pytest.raises(ValueError, match="exceeds"):
        Settings(budget_total_usd=10.0, budget_generation_usd=12.0)


@pytest.mark.integration
def test_schemas_and_extensions(engine: Engine) -> None:
    with engine.connect() as conn:
        schemas = set(
            conn.execute(text("SELECT schema_name FROM information_schema.schemata")).scalars()
        )
        extensions = set(conn.execute(text("SELECT extname FROM pg_extension")).scalars())
    assert {"raw", "core", "ml", "genai"} <= schemas
    assert {"vector", "pg_trgm"} <= extensions


@pytest.mark.integration
def test_mlflow_reachable() -> None:
    url = get_settings().mlflow_tracking_uri.rstrip("/") + "/health"
    with urllib.request.urlopen(url, timeout=10) as r:
        assert r.status == 200
