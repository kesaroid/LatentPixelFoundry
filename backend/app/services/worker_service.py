"""
Worker trigger service.

Decides whether to dispatch to a real cloud GPU worker (via HTTP)
or to the in-process mock worker, based on the MOCK_WORKER setting.
"""

from __future__ import annotations

import asyncio
import uuid

import httpx

from backend.app.core.config import settings
from backend.app.core.database import async_session_factory
from backend.app.core.logging import get_logger
from backend.app.models.job import Job, JobStatus
from backend.app.services import job_service
from backend.app.services.mock_worker import run_mock_worker

logger = get_logger(__name__)

# Timeout for the initial trigger call (worker should respond 202 immediately)
_TRIGGER_TIMEOUT = httpx.Timeout(10.0, connect=5.0)


async def trigger_worker(job: Job) -> None:
    """Trigger video generation for a job.

    In mock mode: spawns an asyncio task running the mock worker.
    In real mode: sends an HTTP POST to the cloud worker endpoint.

    On trigger failure the job is marked FAILED.
    """
    job_id: uuid.UUID = job.id  # type: ignore[assignment]

    try:
        # Mark job as TRIGGERED
        async with async_session_factory() as session:
            await job_service.update_job_status(
                session, job_id, JobStatus.TRIGGERED
            )

        if settings.mock_worker:
            logger.info("Mock mode — spawning mock worker for job %s", job_id)
            asyncio.create_task(run_mock_worker(job_id))
        else:
            await _trigger_real_worker(job)

    except Exception:
        logger.exception("Failed to trigger worker for job %s", job_id)
        try:
            async with async_session_factory() as session:
                await job_service.update_job_status(
                    session,
                    job_id,
                    JobStatus.FAILED,
                    error_message="Failed to trigger worker",
                )
        except Exception:
            logger.exception("Failed to mark job %s as FAILED", job_id)


async def _trigger_real_worker(job: Job) -> None:
    """Send an HTTP POST to the cloud GPU worker.

    Payload follows CONTRACTS.md:
    {
      "job_id": "...",
      "prompt": "...",
      "duration": 5,
      "resolution": "720p",
      "backend_url": "http://backend:8000",
      "upload_url": "http://backend:8000/api/jobs/{id}/upload",
      "status_url": "http://backend:8000/api/jobs/{id}/status"
    }

    The worker is expected to respond immediately with 202 Accepted
    and process the job asynchronously.
    """
    job_id = str(job.id)
    backend_url = settings.backend_url.rstrip("/")

    payload = {
        "job_id": job_id,
        "prompt": job.prompt,
        "duration": job.duration,
        "resolution": job.resolution,
        "backend_url": backend_url,
        "upload_url": f"{backend_url}/api/jobs/{job_id}/upload",
        "status_url": f"{backend_url}/api/jobs/{job_id}/status",
    }

    logger.info(
        "Triggering real worker at %s for job %s",
        settings.worker_url,
        job_id,
    )

    async with httpx.AsyncClient(timeout=_TRIGGER_TIMEOUT) as client:
        response = await client.post(
            settings.worker_url,
            json=payload,
            headers={"X-Worker-API-Key": settings.worker_api_key},
        )
        response.raise_for_status()

    logger.info("Worker accepted job %s (status %d)", job_id, response.status_code)
