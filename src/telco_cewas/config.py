from functools import lru_cache
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    env: Literal["dev", "ci", "prod"] = "dev"
    log_level: str = "INFO"

    database_url: str = Field(
        default="postgresql+psycopg://telco:telco@postgres:5432/telco",
        description="SQLAlchemy conn str:",
    )
    mlflow_tracking_uri: str = "http://mlflow:5000"

    anthropic_api_key: str | None = None
    openai_api_key: str | None = None

    # --- Embedding
    embedding_model: str = "text-embedding-3-small"
    embedding_dimensions: int = 1024

    budget_total_usd: float = 10.00
    budget_embedding_usd: float = 1.00
    budget_generation_usd: float = 9.00
    budget_warn_pct: float = 0.70

    @model_validator(mode="after")
    def _budget_allocations_fit(self) -> "Settings":
        # Sub-budgets must not exceed the total.
        # Caught at startup rather than after the money is gone.

        allocated = self.budget_embedding_usd + self.budget_generation_usd
        if allocated > self.budget_total_usd:
            msg = (
                f"Budget allocations (${allocated:.2f}) exceed the total ceiling "
                f"(${self.budget_total_usd:.2f}). See ADR 0011."
            )
            raise ValueError(msg)
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
