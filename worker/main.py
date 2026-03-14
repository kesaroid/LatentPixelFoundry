"""
GPU worker — FastAPI app on port 9000.
Contract: POST /generate with job payload → 202 Accepted, process async with LTX-2.
"""
from __future__ import annotations

import asyncio
import os
import tempfile
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from pipeline_ltx2 import run as run_ltx2

# Env (set by deploy-worker.sh / docker run)
CHECKPOINT_FILENAME = os.environ.get("CHECKPOINT_FILENAME", "ltx-2-19b-dev-fp8.safetensors")
BACKEND_URL = os.environ.get("BACKEND_URL", "http://backend:8000")
WORKER_API_KEY = os.environ.get("WORKER_API_KEY", "")
MODELS_DIR = os.environ.get("MODELS_DIR", "/models")

# Headers for backend callbacks
def _worker_headers() -> dict[str, str]:
    if not WORKER_API_KEY:
        return {}
    return {"X-Worker-API-Key": WORKER_API_KEY}


async def _run_job(
    job_id: str,
    prompt: str,
    duration: float,
    resolution: str,
    status_url: str,
    upload_url: str,
) -> None:
    """Background: run LTX-2 pipeline, PATCH status, upload MP4."""
    start = time.perf_counter()
    try:
        await _patch_status(status_url, "GENERATING", None, None)
        # Run pipeline in thread (blocking GPU work)
        loop = asyncio.get_event_loop()
        with tempfile.NamedTemporaryFile(suffix=".mp4", delete=False) as f:
            out_path = f.name
        try:
            await loop.run_in_executor(
                None,
                lambda: run_ltx2(
                    prompt,
                    duration_sec=duration,
                    resolution=resolution or "720p",
                    output_path=out_path,
                ),
            )
            elapsed = time.perf_counter() - start
            await _patch_status(status_url, "UPLOADING", None, elapsed)
            # Upload MP4
            with open(out_path, "rb") as f:
                files = {"file": (f"{job_id}.mp4", f, "video/mp4")}
                async with httpx.AsyncClient(timeout=300.0) as client:
                    r = await client.post(
                        upload_url,
                        files=files,
                        headers=_worker_headers(),
                    )
                    r.raise_for_status()
            await _patch_status(status_url, "COMPLETED", None, time.perf_counter() - start)
        finally:
            if os.path.isfile(out_path):
                try:
                    os.unlink(out_path)
                except OSError:
                    pass
    except Exception as e:
        elapsed = time.perf_counter() - start
        await _patch_status(
            status_url,
            "FAILED",
            str(e)[:4000],
            round(elapsed, 2),
        )


async def _patch_status(
    status_url: str,
    status: str,
    error_message: str | None,
    generation_time_seconds: float | None,
) -> None:
    body = {"status": status, "error_message": error_message}
    if generation_time_seconds is not None:
        body["generation_time_seconds"] = generation_time_seconds
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            r = await client.patch(
                status_url,
                json=body,
                headers={**_worker_headers(), "Content-Type": "application/json"},
            )
            r.raise_for_status()
    except Exception as e:
        import logging
        logging.getLogger("worker").warning("PATCH %s failed: %s", status_url, e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield


app = FastAPI(title="LPF GPU Worker", lifespan=lifespan)


@app.get("/health")
async def health():
    """Readiness probe (GET /health)."""
    return {"status": "ok"}


@app.post("/generate")
async def generate(request: Request):
    """
    Accept job from backend. Return 202 immediately; process in background with LTX-2.
    Body: job_id, prompt, duration, resolution, backend_url, upload_url, status_url.
    """
    body = await request.json()
    job_id = body.get("job_id", "")
    prompt = body.get("prompt", "")
    duration = float(body.get("duration", 5))
    resolution = body.get("resolution", "720p")
    status_url = body.get("status_url", "")
    upload_url = body.get("upload_url", "")
    if not status_url or not upload_url:
        return JSONResponse(
            status_code=400,
            content={"detail": "status_url and upload_url required"},
        )
    asyncio.create_task(
        _run_job(job_id, prompt, duration, resolution, status_url, upload_url)
    )
    return JSONResponse(
        status_code=202,
        content={"status": "accepted", "job_id": job_id},
    )
