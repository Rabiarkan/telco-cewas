"""Centralised configuration.

No module touches os.environ directly. A missing or mistyped value fails at
startup instead of surfacing as None three layers down.
"""

from functools import lru_cache
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    env: Literal["dev", "ci", "prod"] = "dev"
    log_level: str = "INFO"

    database_url: str = "postgresql+psycopg://telco:telco@postgres:5432/telco"
    mlflow_tracking_uri: str = "http://mlflow:5000"

    # The only paid provider (Phase 5). Unset until then.
    anthropic_api_key: str | None = None

    # Local embedding, no API key. Pinned rather than passed per call: query and
    # document vectors must use the same model at the same dimension, or cosine
    # similarity compares unrelated spaces. 384 is baked into kb_chunk.embedding.
    embedding_model: str = "BAAI/bge-small-en-v1.5"
    embedding_dimensions: int = 384

    # Hard ceiling on Claude spend. Level 3 of three: the others are the
    # Anthropic console limit and genai.llm_trace.cost_usd. Those exist because
    # a bug in this process can bypass this one.
    budget_total_usd: float = 10.00
    budget_generation_usd: float = 10.00
    budget_warn_pct: float = 0.70

    @model_validator(mode="after")
    def _budget_fits(self) -> "Settings":
        if self.budget_generation_usd > self.budget_total_usd:
            msg = (
                f"Generation budget (${self.budget_generation_usd:.2f}) exceeds "
                f"the total ceiling (${self.budget_total_usd:.2f})."
            )
            raise ValueError(msg)
        return self


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
