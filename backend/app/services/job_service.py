"""
Job data-access service.

Pure async functions wrapping SQLModel CRUD operations on the Job table.
Each function takes an AsyncSession, performs the query, and returns the model.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from backend.app.core.logging import get_logger
from backend.app.models.job import Job, JobCreate, JobStatus

logger = get_logger(__name__)


async def create_job(session: AsyncSession, job_in: JobCreate) -> Job:
    """Insert a new job with PENDING status."""
    job = Job(
        prompt=job_in.prompt,
        duration=job_in.duration,
        resolution=job_in.resolution,
    )
    session.add(job)
    await session.commit()
    await session.refresh(job)
    logger.info("Created job %s — prompt=%r", job.id, job.prompt[:80])
    return job


async def get_job(session: AsyncSession, job_id: uuid.UUID) -> Job | None:
    """Fetch a single job by primary key, or None if not found."""
    return await session.get(Job, job_id)


async def list_jobs(session: AsyncSession) -> list[Job]:
    """Return all jobs ordered newest-first."""
    result = await session.execute(
        select(Job).order_by(Job.created_at.desc())  # type: ignore[attr-defined]
    )
    return list(result.scalars().all())


async def update_job_status(
    session: AsyncSession,
    job_id: uuid.UUID,
    status: JobStatus,
    error_message: Optional[str] = None,
    generation_time_seconds: Optional[float] = None,
) -> Job:
    """Transition a job to a new status and persist.

    Raises:
        ValueError: if the job does not exist.
    """
    job = await session.get(Job, job_id)
    if job is None:
        raise ValueError(f"Job {job_id} not found")

    job.status = status
    job.updated_at = datetime.now(timezone.utc)

    if error_message is not None:
        job.error_message = error_message
    if generation_time_seconds is not None:
        job.generation_time_seconds = generation_time_seconds

    session.add(job)
    await session.commit()
    await session.refresh(job)
    logger.info("Job %s → %s", job_id, status.value)
    return job


async def set_video_path(
    session: AsyncSession,
    job_id: uuid.UUID,
    video_path: str,
) -> Job:
    """Set the local video file path and mark the job COMPLETED.

    Raises:
        ValueError: if the job does not exist.
    """
    job = await session.get(Job, job_id)
    if job is None:
        raise ValueError(f"Job {job_id} not found")

    job.video_path = video_path
    job.status = JobStatus.COMPLETED
    job.updated_at = datetime.now(timezone.utc)

    session.add(job)
    await session.commit()
    await session.refresh(job)
    logger.info("Job %s completed — video at %s", job_id, video_path)
    return job
