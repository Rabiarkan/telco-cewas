"""
Project CLI

Subcommands will be added as the project progresses:
    telco db migrate | data ingest | ml train | ml score | genai recommend
"""

import typer

from telco_cewas.config import get_settings

app = typer.Typer(help="Telco Churn Early Warning & Action System")


@app.command()
def info() -> None:
    """Active configuration:"""
    s = get_settings()
    typer.echo(f"env                 : {s.env}")
    typer.echo(f"database_url        : {s.database_url.split('@')[-1]}")
    typer.echo(f"mlflow_tracking_uri : {s.mlflow_tracking_uri}")
    typer.echo(f"anthropic_api_key   : {'set' if s.anthropic_api_key else 'unset'}")


@app.command()
def healthcheck() -> None:
    """check Postgres connection, schemas and pgvector extension"""
    from sqlalchemy import create_engine, text

    engine = create_engine(get_settings().database_url, pool_pre_ping=True)
    expected = {"raw", "core", "ml", "genai"}
    with engine.connect() as conn:
        version = conn.execute(text("SELECT version()")).scalar_one()
        rows = conn.execute(
            text("SELECT schema_name FROM information_schema.schemata")
        ).scalars()
        found = expected & set(rows)
        has_vector = conn.execute(
            text("SELECT count(*) FROM pg_extension WHERE extname = 'vector'")
        ).scalar_one()

    typer.echo(f"postgres  : {version.split(',')[0]}")
    typer.echo(f"schemas   : {sorted(found)}  (expected {sorted(expected)})")
    typer.echo(f"pgvector  : {'ok' if has_vector else 'MISSING'}")

    if found != expected or not has_vector:
        raise typer.Exit(code=1)
    typer.echo("healthcheck: OK")


if __name__ == "__main__":
    app()