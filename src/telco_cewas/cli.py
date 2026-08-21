"""telco -- project CLI."""

from pathlib import Path

import typer

from telco_cewas.config import get_settings

app = typer.Typer(help="Telco CEWAS", no_args_is_help=True)
db_app = typer.Typer(help="Schema and data", no_args_is_help=True)
app.add_typer(db_app, name="db")


@app.command()
def info() -> None:
    """Show the active configuration with secrets masked."""
    s = get_settings()
    typer.echo(f"env        : {s.env}")
    typer.echo(f"database   : {s.database_url.split('@')[-1]}")
    typer.echo(f"mlflow     : {s.mlflow_tracking_uri}")
    typer.echo(f"anthropic  : {'set' if s.anthropic_api_key else 'unset'}")
    typer.echo(f"embedding  : {s.embedding_model} @ {s.embedding_dimensions}d (local)")
    typer.echo(f"budget     : ${s.budget_total_usd:.2f}")


@app.command()
def healthcheck() -> None:
    """Verify schemas and extensions."""
    from sqlalchemy import text

    from telco_cewas.db import get_engine

    with get_engine().connect() as conn:
        schemas = set(
            conn.execute(text("SELECT schema_name FROM information_schema.schemata")).scalars()
        )
        extensions = set(conn.execute(text("SELECT extname FROM pg_extension")).scalars())

    ok = {"raw", "core", "ml", "genai"} <= schemas and {"vector", "pg_trgm"} <= extensions
    typer.echo(f"schemas    : {sorted({'raw', 'core', 'ml', 'genai'} & schemas)}")
    typer.echo(f"extensions : {sorted({'vector', 'pg_trgm'} & extensions)}")
    if not ok:
        raise typer.Exit(code=1)
    typer.secho("ok", fg=typer.colors.GREEN)


@db_app.command("apply")
def db_apply() -> None:
    """Apply every SQL file in db/sql/ (idempotent)."""
    from telco_cewas.db import apply_all, get_engine

    failed = False
    for r in apply_all(get_engine()):
        if r.error is None:
            typer.echo(f"  ok   {r.name}")
        else:
            typer.secho(f"  FAIL {r.name}\n       {r.error}", fg=typer.colors.RED)
            failed = True
    if failed:
        raise typer.Exit(code=1)


@db_app.command("reset")
def db_reset(yes: bool = typer.Option(False, "--yes")) -> None:
    """Drop all project schemas and re-apply."""
    from telco_cewas.db import apply_all, get_engine, reset

    if not yes:
        typer.confirm("Drop raw/core/ml/genai and all data?", abort=True)

    engine = get_engine()
    reset(engine)
    typer.echo("  dropped schemas")
    for r in apply_all(engine):
        if r.error is None:
            typer.echo(f"  ok   {r.name}")
        else:
            typer.secho(f"  FAIL {r.name}\n       {r.error}", fg=typer.colors.RED)
            raise typer.Exit(code=1)


@db_app.command("ingest")
def db_ingest(path: Path = typer.Option(Path("data/raw"), "--path", "-p")) -> None:
    """Load the source CSVs into raw (truncate and reload)."""
    from telco_cewas.db import get_engine, load_all

    failed = False
    for r in load_all(get_engine(), path):
        if r.error is None:
            typer.echo(f"  ok   raw.{r.table:<13} {r.rows:>6,} rows")
        else:
            typer.secho(f"  FAIL raw.{r.table}\n       {r.error}", fg=typer.colors.RED)
            failed = True
    if failed:
        raise typer.Exit(code=1)


if __name__ == "__main__":
    app()
