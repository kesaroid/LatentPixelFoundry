"""
Video generation model loader and inference using LTX-2.

Loads the LTX-2 TI2VidTwoStagesPipeline on first use via a lazy singleton
pattern, then exposes a simple `generate_video()` function for the worker.

The pipeline is loaded once and kept in memory for the lifetime of the
worker process to avoid expensive re-initialization between jobs.
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
# Resolution presets (width x height) — two-stage pipeline doubles internally
# so these are the final output dimensions.
# ---------------------------------------------------------------------------
RESOLUTION_MAP: dict[str, tuple[int, int]] = {
    "480p": (768, 512),
    "720p": (1280, 768),
    "1080p": (1536, 1024),
}

_DEFAULT_FRAME_RATE: float = 24.0


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
    """Load the LTX-2 TI2VidTwoStagesPipeline on first call.

    Subsequent calls return the cached instance.
    """
    global _pipeline

    if _pipeline is not None:
        return _pipeline

    logger.info(
        "Loading LTX-2 pipeline: checkpoint=%s, device=%s",
        settings.checkpoint_path,
        settings.device,
    )
    start = time.monotonic()

    try:
        from ltx_core.loader import LTXV_LORA_COMFY_RENAMING_MAP, LoraPathStrengthAndSDOps
        from ltx_pipelines.ti2vid_two_stages import TI2VidTwoStagesPipeline

        for path, label in [
            (settings.checkpoint_path, "checkpoint"),
            (settings.distilled_lora_path, "distilled LoRA"),
            (settings.spatial_upsampler_path, "spatial upsampler"),
            (settings.gemma_root, "Gemma text encoder"),
        ]:
            if not path.exists():
                raise FileNotFoundError(
                    f"Required model file not found: {path} ({label}). "
                    "Ensure model files are mounted at the configured model_dir."
                )

        distilled_lora = [
            LoraPathStrengthAndSDOps(
                str(settings.distilled_lora_path),
                settings.distilled_lora_strength,
                LTXV_LORA_COMFY_RENAMING_MAP,
            ),
        ]

        pipe = TI2VidTwoStagesPipeline(
            checkpoint_path=str(settings.checkpoint_path),
            distilled_lora=distilled_lora,
            spatial_upsampler_path=str(settings.spatial_upsampler_path),
            gemma_root=str(settings.gemma_root),
            loras=[],
        )

        _pipeline = pipe
        elapsed = time.monotonic() - start
        logger.info("LTX-2 pipeline loaded in %.1fs", elapsed)
        return _pipeline

    except torch.cuda.OutOfMemoryError:
        logger.error("CUDA out of memory while loading LTX-2 pipeline")
        raise RuntimeError(
            "Not enough GPU memory to load LTX-2 19B. "
            "Consider using the FP8 checkpoint or a larger GPU."
        )
    except FileNotFoundError:
        raise
    except Exception as exc:
        logger.error("Failed to load LTX-2 pipeline: %s", exc)
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
    from ltx_core.components.guiders import MultiModalGuiderParams
    from ltx_core.model.video_vae import TilingConfig, get_video_chunks_number
    from ltx_pipelines.utils.constants import AUDIO_SAMPLE_RATE
    from ltx_pipelines.utils.media_io import encode_video

    pipe = _get_pipeline()

    width, height = RESOLUTION_MAP.get(resolution, RESOLUTION_MAP["720p"])
    frame_rate = settings.frame_rate
    num_frames = max(int(duration * frame_rate), 1)
    # LTX-2 expects an odd number of frames (2n+1 pattern)
    if num_frames % 2 == 0:
        num_frames += 1

    logger.info(
        "Generating video: prompt=%r, duration=%ds, resolution=%s (%dx%d), frames=%d",
        prompt[:80],
        duration,
        resolution,
        width,
        height,
        num_frames,
    )

    video_guider_params = MultiModalGuiderParams(
        cfg_scale=settings.video_cfg_scale,
        stg_scale=settings.video_stg_scale,
        rescale_scale=settings.video_rescale_scale,
        modality_scale=settings.video_modality_scale,
        skip_step=0,
        stg_blocks=settings.video_stg_blocks,
    )

    audio_guider_params = MultiModalGuiderParams(
        cfg_scale=settings.audio_cfg_scale,
        stg_scale=settings.audio_stg_scale,
        rescale_scale=settings.audio_rescale_scale,
        modality_scale=settings.audio_modality_scale,
        skip_step=0,
        stg_blocks=settings.audio_stg_blocks,
    )

    start = time.monotonic()

    try:
        tiling_config = TilingConfig.default()
        video_chunks_number = get_video_chunks_number(num_frames, tiling_config)

        from ltx_pipelines.utils.constants import DEFAULT_NEGATIVE_PROMPT

        video, audio = pipe(
            prompt=prompt,
            negative_prompt=DEFAULT_NEGATIVE_PROMPT,
            seed=int(time.time()) % (2**31),
            height=height,
            width=width,
            num_frames=num_frames,
            frame_rate=frame_rate,
            num_inference_steps=settings.num_inference_steps,
            video_guider_params=video_guider_params,
            audio_guider_params=audio_guider_params,
            images=[],
            tiling_config=tiling_config,
        )

        output_path.parent.mkdir(parents=True, exist_ok=True)

        encode_video(
            video=video,
            fps=frame_rate,
            audio=audio,
            audio_sample_rate=AUDIO_SAMPLE_RATE,
            output_path=str(output_path),
            video_chunks_number=video_chunks_number,
        )

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
