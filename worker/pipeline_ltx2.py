"""
LTX-2 two-stage text-to-video pipeline.
Loads from /models/ltx2 (downloaded by download_all_models.sh) — no Hub cache.
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import torch

MODELS_DIR = os.environ.get("MODELS_DIR", "/models")
LTX2_LOCAL_PATH = os.path.join(MODELS_DIR, "ltx2")

# Resolution presets (width, height) — LTX-2 example uses 768x512
RESOLUTION_MAP = {
    "480p": (768, 512),
    "720p": (768, 512),
    "1080p": (768, 512),
}
DEFAULT_RESOLUTION = (768, 512)
FRAME_RATE = 24.0
NEGATIVE_PROMPT = (
    "shaky, glitchy, low quality, worst quality, deformed, distorted, disfigured, "
    "motion smear, motion artifacts, fused fingers, bad anatomy, weird hand, ugly, transition, static."
)


def run(
    prompt: str,
    *,
    duration_sec: float = 5.0,
    resolution: str = "720p",
    output_path: str | Path = "output.mp4",
    num_inference_steps_stage1: int = 40,
    guidance_scale: float = 4.0,
    seed: int | None = None,
) -> str:
    """
    Run two-stage LTX-2 text-to-video, save MP4. Returns path to the file.
    """
    from diffusers import FlowMatchEulerDiscreteScheduler
    from diffusers.pipelines.ltx2 import LTX2Pipeline, LTX2LatentUpsamplePipeline
    from diffusers.pipelines.ltx2.export_utils import encode_video
    from diffusers.pipelines.ltx2.latent_upsampler import LTX2LatentUpsamplerModel
    from diffusers.pipelines.ltx2.utils import STAGE_2_DISTILLED_SIGMA_VALUES

    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    width, height = RESOLUTION_MAP.get(resolution, DEFAULT_RESOLUTION)
    num_frames = max(49, min(121, int(duration_sec * FRAME_RATE)))  # LTX-2 typical range
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    generator = None
    if seed is not None:
        generator = torch.Generator(device=device).manual_seed(seed)

    # Load from /models/ltx2 (run download_all_models.sh first)
    if not os.path.isdir(LTX2_LOCAL_PATH) or not os.path.isfile(
        os.path.join(LTX2_LOCAL_PATH, "model_index.json")
    ):
        raise FileNotFoundError(
            f"LTX-2 models not found at {LTX2_LOCAL_PATH}. "
            "Run worker/scripts/download_all_models.sh on the instance first."
        )
    pipe = LTX2Pipeline.from_pretrained(
        LTX2_LOCAL_PATH,
        torch_dtype=torch.bfloat16,
        local_files_only=True,
    )
    pipe.enable_sequential_cpu_offload(device=device)

    # Stage 1
    video_latent, audio_latent = pipe(
        prompt=prompt,
        negative_prompt=NEGATIVE_PROMPT,
        width=width,
        height=height,
        num_frames=num_frames,
        frame_rate=FRAME_RATE,
        num_inference_steps=num_inference_steps_stage1,
        sigmas=None,
        guidance_scale=guidance_scale,
        generator=generator,
        output_type="latent",
        return_dict=False,
    )

    latent_upsampler = LTX2LatentUpsamplerModel.from_pretrained(
        LTX2_LOCAL_PATH,
        subfolder="latent_upsampler",
        torch_dtype=torch.bfloat16,
        local_files_only=True,
    )
    upsample_pipe = LTX2LatentUpsamplePipeline(vae=pipe.vae, latent_upsampler=latent_upsampler)
    upsample_pipe.enable_model_cpu_offload(device=device)
    upscaled_video_latent = upsample_pipe(
        latents=video_latent,
        output_type="latent",
        return_dict=False,
    )[0]

    # Stage handoff: make sure GPU is actually freed before stage 2.
    # `enable_*_cpu_offload` primarily manages *model weights*, but stage 1/2 reuse
    # shared modules (notably `pipe.vae`) and can leave the last-used components
    # resident on GPU. That leaves Accelerate with essentially no free VRAM when
    # it tries to move `text_encoder` for `encode_prompt` in stage 2.
    if torch.cuda.is_available() and device.startswith("cuda"):
        del upsample_pipe, latent_upsampler
        # `video_latent` is no longer needed after upsampling.
        del video_latent
        torch.cuda.empty_cache()
        # Force all diffusion modules back to CPU, then re-enable sequential
        # offload so the next stage starts from a clean memory baseline.
        pipe.to("cpu")
        pipe.enable_sequential_cpu_offload(device=device)

    # Stage 2 distilled LoRA
    pipe.load_lora_weights(
        LTX2_LOCAL_PATH,
        adapter_name="stage_2_distilled",
        weight_name="ltx-2-19b-distilled-lora-384.safetensors",
        local_files_only=True,
    )
    pipe.set_adapters("stage_2_distilled", 1.0)
    pipe.vae.enable_tiling()
    new_scheduler = FlowMatchEulerDiscreteScheduler.from_config(
        pipe.scheduler.config, use_dynamic_shifting=False, shift_terminal=None
    )
    pipe.scheduler = new_scheduler

    video, audio = pipe(
        latents=upscaled_video_latent,
        audio_latents=audio_latent,
        prompt=prompt,
        negative_prompt=NEGATIVE_PROMPT,
        num_inference_steps=3,
        noise_scale=STAGE_2_DISTILLED_SIGMA_VALUES[0],
        sigmas=STAGE_2_DISTILLED_SIGMA_VALUES,
        guidance_scale=1.0,
        generator=generator,
        output_type="np",
        return_dict=False,
    )

    encode_video(
        video[0],
        fps=FRAME_RATE,
        audio=audio[0].float().cpu(),
        audio_sample_rate=pipe.vocoder.config.output_sampling_rate,
        output_path=str(output_path),
    )
    return str(output_path.resolve())
