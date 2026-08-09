from functools import lru_cache
from typing import Literal

from pydantic import Field
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


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()