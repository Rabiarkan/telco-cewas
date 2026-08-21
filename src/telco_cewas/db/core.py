"""Connection and schema application.

Every file in sql/ is applied on every run. That works because every statement
is idempotent, which is why there is no migration ledger.
"""

from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

from sqlalchemy import Engine, create_engine, text

from telco_cewas.config import get_settings

SCHEMAS = ("genai", "ml", "core", "raw")
SQL_DIR = Path(__file__).resolve().parent / "sql"


@lru_cache(maxsize=1)
def get_engine() -> Engine:
    """One engine per process; pool_pre_ping survives Postgres restarts."""
    return create_engine(get_settings().database_url, pool_pre_ping=True, pool_size=5)


@dataclass(frozen=True)
class Applied:
    name: str
    error: str | None = None


def sql_files() -> list[Path]:
    """Filename order. Prefixes are zero-padded so '010' sorts before '020'."""
    return sorted(SQL_DIR.glob("*.sql"))


def apply_all(engine: Engine) -> list[Applied]:
    """Apply each file in its own transaction, stopping at the first failure."""
    results = []
    for path in sql_files():
        try:
            with engine.begin() as conn:
                conn.exec_driver_sql(path.read_text())
            results.append(Applied(path.name))
        except Exception as exc:
            results.append(Applied(path.name, str(exc).strip()))
            break
    return results


def reset(engine: Engine) -> None:
    """Drop all project schemas. Caller re-applies afterwards."""
    with engine.begin() as conn:
        for schema in SCHEMAS:
            conn.execute(text(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'))
