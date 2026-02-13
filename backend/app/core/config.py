"""
Application settings loaded from environment variables.

Uses Pydantic Settings so .env files are auto-loaded.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Central configuration — all values come from env vars / .env file."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # --- Database ---
    postgres_user: str = "videogen"
    postgres_password: str = "videogen_dev_password"
    postgres_db: str = "videogen"
    postgres_host: str = "postgres"
    postgres_port: int = 5432
    database_url: Optional[str] = None

    @property
    def effective_database_url(self) -> str:
        if self.database_url:
            return self.database_url
        return (
            f"postgresql+asyncpg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    # --- Backend ---
    backend_host: str = "0.0.0.0"
    backend_port: int = 8000

    # --- Worker auth ---
    worker_api_key: str = "change-me-to-a-secure-random-string"

    # --- Worker trigger ---
    mock_worker: bool = True
    mock_delay_seconds: int = 5
    worker_url: str = "http://localhost:9000/generate"
    backend_url: str = "http://backend:8000"

    # --- Video defaults ---
    default_duration: int = 5
    default_resolution: str = "720p"

    # --- Logging ---
    log_level: str = "INFO"

    # --- Paths ---
    generated_videos_dir: Path = Path("generated_videos")


settings = Settings()
