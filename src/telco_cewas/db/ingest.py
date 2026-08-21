"""Load the source CSVs into raw, verbatim.

Truncate-and-reload, so running twice does not duplicate. The CSV header is
checked against the table's real columns first: mirrors of this dataset differ
in naming, and a silent mismatch leaves columns empty.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import Engine, text

SOURCES = {
    "demographics": "Telco_customer_churn_demographics.csv",
    "location": "Telco_customer_churn_location.csv",
    "population": "Telco_customer_churn_population.csv",
    "services": "Telco_customer_churn_services.csv",
    "status": "Telco_customer_churn_status.csv",
}


@dataclass(frozen=True)
class Loaded:
    table: str
    rows: int
    error: str | None = None


def table_columns(engine: Engine, table: str) -> list[str]:
    """Read columns from the catalogue so the DDL stays the only definition."""
    with engine.connect() as conn:
        cols = conn.execute(
            text("""
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'raw' AND table_name = :t
                ORDER BY ordinal_position
            """),
            {"t": table},
        ).scalars()
    return [c for c in cols if not c.startswith("_")]


def csv_header(path: Path) -> list[str]:
    """utf-8-sig strips the BOM that Excel-saved files carry."""
    with path.open(encoding="utf-8-sig", newline="") as f:
        return next(csv.reader(f))


def load(engine: Engine, table: str, path: Path) -> Loaded:
    if not path.is_file():
        return Loaded(table, 0, f"not found: {path}")

    try:
        expected = set(table_columns(engine, table))
        header = csv_header(path)
        if expected != set(header):
            missing = sorted(expected - set(header))
            extra = sorted(set(header) - expected)
            msg = f"header mismatch: missing={missing} unexpected={extra}"
            raise ValueError(msg)

        cols = ", ".join(f'"{c}"' for c in header)
        with engine.begin() as conn:
            conn.execute(text(f"TRUNCATE raw.{table}"))
            # COPY FROM STDIN is a psycopg feature, not exposed by SQLAlchemy Core.
            cur = conn.connection.driver_connection.cursor()
            copy_sql = f"COPY raw.{table} ({cols}) FROM STDIN WITH (FORMAT csv, HEADER true)"
            with cur.copy(copy_sql) as copy, path.open("rb") as fh:
                while chunk := fh.read(64 * 1024):
                    copy.write(chunk)
            conn.execute(text(f"UPDATE raw.{table} SET _source_file = :f"), {"f": path.name})
            rows = conn.execute(text(f"SELECT count(*) FROM raw.{table}")).scalar_one()
    except Exception as exc:
        return Loaded(table, 0, str(exc).strip())

    return Loaded(table, rows)


def load_all(engine: Engine, directory: Path) -> list[Loaded]:
    """One bad file should not hide the status of the other four."""
    return [load(engine, t, directory / f) for t, f in SOURCES.items()]
