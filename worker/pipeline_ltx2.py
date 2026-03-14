"""
LTX-2 two-stage text-to-video pipeline.
Loads from Hugging Face (cache under MODELS_DIR if set), runs Stage 1 + upsampler + Stage 2 LoRA, encodes to MP4.
"""
from __future__ import annotations

import os
import time
from pathlib import Path

import torch

# Optional: use /models as Hugging Face cache so downloads stay on the volume
MODELS_DIR = os.environ.get("MODELS_DIR", "/models")
if os.path.isdir(MODELS_DIR):
    os.environ.setdefault("HF_HOME", MODELS_DIR)
    os.environ.setdefault("HF_HUB_CACHE", os.path.join(MODELS_DIR, "hub"))

# HF Hub token from .env (HUGGING_FACE_API_KEY) so downloads are authenticated and rate limits are higher
if not os.environ.get("HF_TOKEN") and os.environ.get("HUGGING_FACE_API_KEY"):
    os.environ["HF_TOKEN"] = os.environ["HUGGING_FACE_API_KEY"]

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

    # Load pipeline from Hub (cache under MODELS_DIR when HF_HOME is set)
    pipe = LTX2Pipeline.from_pretrained(
        "Lightricks/LTX-2",
        torch_dtype=torch.bfloat16,
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
        "Lightricks/LTX-2",
        subfolder="latent_upsampler",
        torch_dtype=torch.bfloat16,
    )
    upsample_pipe = LTX2LatentUpsamplePipeline(vae=pipe.vae, latent_upsampler=latent_upsampler)
    upsample_pipe.enable_model_cpu_offload(device=device)
    upscaled_video_latent = upsample_pipe(
        latents=video_latent,
        output_type="latent",
        return_dict=False,
    )[0]

    # Stage 2 distilled LoRA
    pipe.load_lora_weights(
        "Lightricks/LTX-2",
        adapter_name="stage_2_distilled",
        weight_name="ltx-2-19b-distilled-lora-384.safetensors",
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
