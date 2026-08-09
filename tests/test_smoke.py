"""Phase 1 acceptance tests: Is the infrastructure up and running?"""

import pytest

from telco_cewas.config import get_settings


def test_settings_loads() -> None:
    s = get_settings()
    assert s.database_url.startswith("postgresql")
    assert s.mlflow_tracking_uri


@pytest.mark.integration
def test_postgres_schemas_exist() -> None:
    from sqlalchemy import create_engine, text

    engine = create_engine(get_settings().database_url, pool_pre_ping=True)
    with engine.connect() as conn:
        schemas = set(
            conn.execute(text("SELECT schema_name FROM information_schema.schemata")).scalars()
        )
    assert {"raw", "core", "ml", "genai"} <= schemas


@pytest.mark.integration
def test_pgvector_available() -> None:
    from sqlalchemy import create_engine, text

    engine = create_engine(get_settings().database_url, pool_pre_ping=True)
    with engine.connect() as conn:
        n = conn.execute(
            text("SELECT count(*) FROM pg_extension WHERE extname = 'vector'")
        ).scalar_one()
    assert n == 1


@pytest.mark.integration
def test_mlflow_reachable() -> None:
    import urllib.request

    url = get_settings().mlflow_tracking_uri.rstrip("/") + "/health"
    with urllib.request.urlopen(url, timeout=10) as r:
        assert r.status == 200
