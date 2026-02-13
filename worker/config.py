"""
Worker configuration loaded from environment variables.

Uses Pydantic Settings so .env files are auto-loaded.
All secrets (API keys) come from env vars — never hardcoded.
"""

from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class WorkerSettings(BaseSettings):
    """Configuration for the GPU worker service."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # --- Authentication ---
    worker_api_key: str = "change-me-to-a-secure-random-string"

    # --- Backend connection ---
    backend_url: str = "http://backend:8000"

    # --- Video model ---
    model_id: str = "THUDM/CogVideoX-2b"
    device: str = "cuda"

    # --- Temp storage ---
    temp_dir: Path = Path("/tmp/videogen")

    # --- Server ---
    worker_host: str = "0.0.0.0"
    worker_port: int = 9000

    # --- Retry / timeout ---
    max_retries: int = 3
    retry_delay: float = 2.0
    upload_timeout: float = 300.0

    # --- Logging ---
    log_level: str = "INFO"


settings = WorkerSettings()
