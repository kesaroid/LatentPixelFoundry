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

    # --- LTX-2 model files (volume-mounted at model_dir) ---
    model_dir: Path = Path("/models")
    # FP8 (~25GB) fits g5.xlarge/2xlarge (32GB RAM). Full (~43GB) needs vm.overcommit_memory=1 or 64GB+ RAM.
    checkpoint_filename: str = "ltx-2-19b-dev-fp8.safetensors"
    distilled_lora_filename: str = "ltx-2-19b-distilled-lora-384.safetensors"
    spatial_upsampler_filename: str = "ltx-2-spatial-upsampler-x2-1.0.safetensors"
    gemma_dir_name: str = "gemma-3"
    distilled_lora_strength: float = 0.6
    # FP8 runtime quantization reduces VRAM ~40%; enable for 24GB GPUs (g5.xlarge, g5.2xlarge)
    enable_fp8: bool = True

    # --- LTX-2 inference parameters ---
    # Fewer steps = less VRAM; 20–30 for low-VRAM, 40 for quality
    num_inference_steps: int = 25
    frame_rate: float = 24.0
    video_cfg_scale: float = 3.0
    video_stg_scale: float = 1.0
    video_rescale_scale: float = 0.7
    video_modality_scale: float = 3.0
    video_stg_blocks: list[int] = [29]
    audio_cfg_scale: float = 7.0
    audio_stg_scale: float = 1.0
    audio_rescale_scale: float = 0.7
    audio_modality_scale: float = 3.0
    audio_stg_blocks: list[int] = [29]

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

    # --- Derived paths ---
    @property
    def checkpoint_path(self) -> Path:
        return self.model_dir / self.checkpoint_filename

    @property
    def distilled_lora_path(self) -> Path:
        return self.model_dir / self.distilled_lora_filename

    @property
    def spatial_upsampler_path(self) -> Path:
        return self.model_dir / self.spatial_upsampler_filename

    @property
    def gemma_root(self) -> Path:
        return self.model_dir / self.gemma_dir_name


settings = WorkerSettings()
