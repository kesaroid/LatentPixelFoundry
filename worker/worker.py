"""
GPU Worker — FastAPI application for video generation.

Endpoints:
    GET  /health    — Readiness probe for load balancers.
    POST /generate  — Accepts a job payload, returns 202 Accepted,
                      and processes the job asynchronously in the background.

The worker communicates back to the backend via the BackendClient,
updating job status at each stage and uploading the finished video.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import BackgroundTasks, FastAPI
from pydantic import BaseModel, Field

from worker.backend_client import BackendClient
from worker.config import settings
from worker.model_loader import generate_video

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def _setup_logging() -> None:
    """Configure structured logging for the worker process."""
    log_format = "%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
    logging.basicConfig(
        level=getattr(logging, settings.log_level.upper(), logging.INFO),
        format=log_format,
        handlers=[logging.StreamHandler(sys.stdout)],
        force=True,
    )
    # Silence noisy libraries
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
    logging.getLogger("ltx_core").setLevel(logging.WARNING)
    logging.getLogger("ltx_pipelines").setLevel(logging.WARNING)
    logging.getLogger("transformers").setLevel(logging.WARNING)


logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Request / Response schemas
# ---------------------------------------------------------------------------


class GenerateRequest(BaseModel):
    """Payload sent by the backend to trigger video generation."""

    job_id: str = Field(..., description="UUID of the job")
    prompt: str = Field(..., min_length=1, description="Text prompt for generation")
    duration: int = Field(default=5, ge=1, le=30, description="Duration in seconds")
    resolution: str = Field(default="720p", description="Resolution key")
    backend_url: str = Field(..., description="Backend base URL for callbacks")
    upload_url: str = Field(..., description="Full URL for video upload")
    status_url: str = Field(..., description="Full URL for status updates")


class HealthResponse(BaseModel):
    status: str = "ok"


class AcceptedResponse(BaseModel):
    status: str = "accepted"
    job_id: str


# ---------------------------------------------------------------------------
# Application lifespan
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown hooks."""
    _setup_logging()

    # Ensure temp directory exists
    settings.temp_dir.mkdir(parents=True, exist_ok=True)
    logger.info(
        "Worker started — checkpoint=%s, device=%s, temp_dir=%s",
        settings.checkpoint_path,
        settings.device,
        settings.temp_dir,
    )

    yield

    # Cleanup: remove any leftover temp files
    if settings.temp_dir.exists():
        remaining = list(settings.temp_dir.glob("*.mp4"))
        if remaining:
            logger.warning("Cleaning up %d leftover temp files", len(remaining))
            for f in remaining:
                f.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Video Generation Worker",
    version="1.0.0",
    lifespan=lifespan,
)


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    """Readiness probe — always returns ok if the process is alive."""
    return HealthResponse()


@app.post("/generate", response_model=AcceptedResponse, status_code=202)
async def generate(request: GenerateRequest, background_tasks: BackgroundTasks) -> AcceptedResponse:
    """Accept a video generation job and process it asynchronously.

    Returns 202 Accepted immediately. The actual generation and upload
    happen in a background task.
    """
    logger.info(
        "Received job %s: prompt=%r, duration=%d, resolution=%s",
        request.job_id,
        request.prompt[:80],
        request.duration,
        request.resolution,
    )
    background_tasks.add_task(process_job, request)
    return AcceptedResponse(job_id=request.job_id)


# ---------------------------------------------------------------------------
# Background job processing
# ---------------------------------------------------------------------------


async def process_job(request: GenerateRequest) -> None:
    """Orchestrate the full lifecycle of a video generation job.

    1. Update status -> GENERATING
    2. Run model inference
    3. Update status -> UPLOADING
    4. Upload video to backend
    5. Clean up temp file

    On any failure, status is set to FAILED with an error message.
    """
    client = BackendClient()
    temp_path = settings.temp_dir / f"{request.job_id}.mp4"

    try:
        # --- Stage 1: Generating ---
        await client.update_status(request.job_id, "GENERATING")

        # Run inference in a thread pool to avoid blocking the event loop
        loop = asyncio.get_event_loop()
        result = await loop.run_in_executor(
            None,
            generate_video,
            request.prompt,
            request.duration,
            request.resolution,
            temp_path,
        )

        logger.info(
            "Job %s generation complete in %.1fs",
            request.job_id,
            result.generation_time_seconds,
        )

        # --- Stage 2: Uploading ---
        await client.update_status(
            request.job_id,
            "UPLOADING",
            generation_time_seconds=result.generation_time_seconds,
        )

        await client.upload_video(request.job_id, result.output_path)

        logger.info("Job %s completed successfully", request.job_id)

    except Exception as exc:
        error_msg = f"{type(exc).__name__}: {exc}"
        logger.error("Job %s failed: %s", request.job_id, error_msg)

        try:
            await client.update_status(
                request.job_id,
                "FAILED",
                error_message=error_msg[:4000],
            )
        except Exception as status_exc:
            logger.error(
                "Failed to report FAILED status for job %s: %s",
                request.job_id,
                status_exc,
            )

    finally:
        # Always clean up temp files
        _cleanup_temp(temp_path)


def _cleanup_temp(path: Path) -> None:
    """Remove a temp file, logging but not raising on failure."""
    try:
        if path.exists():
            path.unlink()
            logger.info("Cleaned up temp file: %s", path)
    except OSError as exc:
        logger.warning("Failed to clean up temp file %s: %s", path, exc)


# ---------------------------------------------------------------------------
# Entry point (for direct execution / debugging)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "worker.worker:app",
        host=settings.worker_host,
        port=settings.worker_port,
        log_level=settings.log_level.lower(),
    )
