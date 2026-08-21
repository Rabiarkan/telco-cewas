"""Schema application, ingest, and the source invariants that matter."""

from pathlib import Path

import pytest
from sqlalchemy import Engine, text

from telco_cewas.db import apply_all, get_engine, load_all, sql_files

DATA = Path("data/raw")


@pytest.fixture(scope="module")
def engine() -> Engine:
    return get_engine()


def test_sql_files_are_ordered() -> None:
    """Lexicographic sort, so prefixes must be zero-padded: '010' before '020'."""
    names = [p.name for p in sql_files()]
    assert names
    assert all(n[:3].isdigit() for n in names)


@pytest.mark.integration
def test_apply_is_idempotent(engine: Engine) -> None:
    """Applying twice must not error -- this is what replaces a migration ledger."""
    for _ in range(2):
        assert all(r.error is None for r in apply_all(engine))


@pytest.mark.integration
def test_ingest_is_idempotent(engine: Engine) -> None:
    """Truncate-and-reload: row counts stay the same on a second run."""
    load_all(engine, DATA)
    results = {r.table: r.rows for r in load_all(engine, DATA)}
    assert results["services"] == 7043
    assert results["population"] == 1671


@pytest.mark.integration
def test_core_tables_and_unknown_members(engine: Engine) -> None:
    """Facts use NOT NULL foreign keys; the -1 row is what makes that possible."""
    dims = {
        "dim_customer": "customer_key",
        "dim_location": "location_key",
        "dim_contract": "contract_key",
        "dim_service": "service_key",
        "dim_offer": "offer_key",
        "dim_churn_reason": "reason_key",
    }
    with engine.connect() as conn:
        for table, key in dims.items():
            n = conn.execute(
                text(f"SELECT count(*) FROM core.{table} WHERE {key} = -1")
            ).scalar_one()
            assert n == 1, table


@pytest.mark.integration
def test_revenue_identity_holds(engine: Engine) -> None:
    """An accounting identity in the source. If it fails we are misreading a column."""
    with engine.connect() as conn:
        bad = conn.execute(
            text("""
                SELECT count(*) FROM raw.services
                WHERE abs(NULLIF("TotalRevenue", '')::numeric
                    - (COALESCE(NULLIF("TotalCharges", ''), '0')::numeric
                     + COALESCE(NULLIF("TotalExtraDataCharges", ''), '0')::numeric
                     + COALESCE(NULLIF("TotalLongDistanceCharges", ''), '0')::numeric
                     - COALESCE(NULLIF("TotalRefunds", ''), '0')::numeric)) > 0.01
            """)
        ).scalar_one()
    assert bad == 0


@pytest.mark.integration
def test_churn_reason_only_for_churned(engine: Engine) -> None:
    """Why ChurnReason is forbidden as a feature: its presence reveals the label."""
    with engine.connect() as conn:
        bad = conn.execute(
            text("""
                SELECT count(*) FROM raw.status
                WHERE "CustomerStatus" <> 'Churned' AND NULLIF("ChurnReason", '') IS NOT NULL
            """)
        ).scalar_one()
    assert bad == 0


@pytest.mark.integration
def test_embedding_dimension_matches_config(engine: Engine) -> None:
    from telco_cewas.config import get_settings

    with engine.connect() as conn:
        dim = conn.execute(
            text("""
                SELECT a.atttypmod FROM pg_attribute a
                JOIN pg_class c ON c.oid = a.attrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'genai' AND c.relname = 'kb_chunk' AND a.attname = 'embedding'
            """)
        ).scalar_one()
    assert dim == get_settings().embedding_dimensions
