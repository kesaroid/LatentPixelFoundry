"""
Video generation model loader and inference.

Loads a HuggingFace diffusers video pipeline (CogVideoX-2b by default)
on first use via a lazy singleton pattern, then exposes a simple
`generate_video()` function for the worker to call.

The model is loaded once and kept in memory for the lifetime of the
worker process. This avoids re-downloading / re-loading between jobs.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import torch

from worker.config import settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Resolution presets (width x height)
# ---------------------------------------------------------------------------
RESOLUTION_MAP: dict[str, tuple[int, int]] = {
    "480p": (854, 480),
    "720p": (1280, 720),
    "1080p": (1920, 1080),
}

# CogVideoX generates at ~8 fps
_DEFAULT_FPS: int = 8


@dataclass
class GenerationResult:
    """Output of a video generation run."""

    output_path: Path
    generation_time_seconds: float


# ---------------------------------------------------------------------------
# Lazy model singleton
# ---------------------------------------------------------------------------

_pipeline: Optional[object] = None


def _get_pipeline():
    """Load the video diffusion pipeline on first call.

    Subsequent calls return the cached instance.
    """
    global _pipeline

    if _pipeline is not None:
        return _pipeline

    logger.info("Loading video model: %s on device: %s", settings.model_id, settings.device)
    start = time.monotonic()

    try:
        from diffusers import CogVideoXPipeline
        from diffusers.utils import export_to_video as _  # noqa: F401 — validate import

        pipe = CogVideoXPipeline.from_pretrained(
            settings.model_id,
            torch_dtype=torch.float16,
        )
        pipe = pipe.to(settings.device)

        # Enable memory-efficient attention if available
        try:
            pipe.enable_model_cpu_offload()
            logger.info("Enabled model CPU offload for memory efficiency")
        except Exception:
            logger.info("CPU offload not available, using standard CUDA placement")

        _pipeline = pipe
        elapsed = time.monotonic() - start
        logger.info("Model loaded in %.1fs", elapsed)
        return _pipeline

    except torch.cuda.OutOfMemoryError:
        logger.error("CUDA out of memory while loading model")
        raise RuntimeError(
            f"Not enough GPU memory to load {settings.model_id}. "
            "Consider using a smaller model or a larger GPU."
        )
    except Exception as exc:
        logger.error("Failed to load model %s: %s", settings.model_id, exc)
        raise RuntimeError(f"Model loading failed: {exc}") from exc


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def generate_video(
    prompt: str,
    duration: int,
    resolution: str,
    output_path: Path,
) -> GenerationResult:
    """Generate a video from a text prompt and save it to disk.

    Args:
        prompt: Text description of the desired video.
        duration: Video length in seconds.
        resolution: Resolution key (e.g. "720p").
        output_path: Where to write the .mp4 file.

    Returns:
        GenerationResult with the output path and wall-clock generation time.

    Raises:
        RuntimeError: If model loading or inference fails.
    """
    from diffusers.utils import export_to_video

    pipe = _get_pipeline()

    width, height = RESOLUTION_MAP.get(resolution, RESOLUTION_MAP["720p"])
    num_frames = max(duration * _DEFAULT_FPS, 1)

    logger.info(
        "Generating video: prompt=%r, duration=%ds, resolution=%s (%dx%d), frames=%d",
        prompt[:80],
        duration,
        resolution,
        width,
        height,
        num_frames,
    )

    start = time.monotonic()

    try:
        result = pipe(
            prompt=prompt,
            num_frames=num_frames,
            width=width,
            height=height,
            num_inference_steps=50,
            guidance_scale=6.0,
        )
        frames = result.frames[0]  # first (only) batch entry

        # Ensure parent directory exists
        output_path.parent.mkdir(parents=True, exist_ok=True)

        export_to_video(frames, str(output_path), fps=_DEFAULT_FPS)

        elapsed = time.monotonic() - start
        logger.info(
            "Video generated in %.1fs -> %s (%.1f MB)",
            elapsed,
            output_path,
            output_path.stat().st_size / (1024 * 1024),
        )

        return GenerationResult(
            output_path=output_path,
            generation_time_seconds=round(elapsed, 2),
        )

    except torch.cuda.OutOfMemoryError:
        logger.error("CUDA OOM during generation for prompt: %s", prompt[:80])
        raise RuntimeError(
            "GPU out of memory during video generation. "
            "Try a shorter duration or lower resolution."
        )
    except Exception as exc:
        logger.error("Video generation failed: %s", exc)
        raise RuntimeError(f"Video generation failed: {exc}") from exc
