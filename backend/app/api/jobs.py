"""
Jobs API router — all endpoints for creating, listing, downloading,
uploading, and updating video generation jobs.

Endpoint summary (see CONTRACTS.md for full spec):
  POST   /api/jobs                 — create a new job
  GET    /api/jobs                 — list all jobs (newest first)
  GET    /api/jobs/{job_id}        — get single job
  GET    /api/jobs/{job_id}/download — download generated video
  POST   /api/jobs/{job_id}/upload — worker uploads video (auth required)
  PATCH  /api/jobs/{job_id}/status — worker updates job status (auth required)
"""

from __future__ import annotations

import uuid
from pathlib import Path

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    UploadFile,
    status,
)
from fastapi.responses import FileResponse
from sqlalchemy.ext.asyncio import AsyncSession

from backend.app.api.deps import get_session, verify_worker_api_key
from backend.app.core.config import settings
from backend.app.core.logging import get_logger
from backend.app.models.job import JobCreate, JobRead, JobStatus, JobStatusUpdate
from backend.app.services import job_service
from backend.app.services.worker_service import trigger_worker

logger = get_logger(__name__)

router = APIRouter(prefix="/jobs", tags=["jobs"])

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_UPLOAD_CHUNK_SIZE = 1024 * 1024  # 1 MB chunks for streaming upload


# ---------------------------------------------------------------------------
# POST /api/jobs — create a new job
# ---------------------------------------------------------------------------
@router.post("", response_model=JobRead, status_code=status.HTTP_201_CREATED)
async def create_job(
    body: JobCreate,
    background_tasks: BackgroundTasks,
    session: AsyncSession = Depends(get_session),
) -> JobRead:
    """Create a new video generation job and trigger the worker."""
    job = await job_service.create_job(session, body)
    background_tasks.add_task(trigger_worker, job)
    return JobRead.model_validate(job)


# ---------------------------------------------------------------------------
# GET /api/jobs — list all jobs
# ---------------------------------------------------------------------------
@router.get("", response_model=list[JobRead])
async def list_jobs(
    session: AsyncSession = Depends(get_session),
) -> list[JobRead]:
    """List all jobs ordered by creation date (newest first)."""
    jobs = await job_service.list_jobs(session)
    return [JobRead.model_validate(j) for j in jobs]


# ---------------------------------------------------------------------------
# GET /api/jobs/{job_id} — get single job
# ---------------------------------------------------------------------------
@router.get("/{job_id}", response_model=JobRead)
async def get_job(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
) -> JobRead:
    """Retrieve a single job by ID."""
    job = await job_service.get_job(session, job_id)
    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Job not found",
        )
    return JobRead.model_validate(job)


# ---------------------------------------------------------------------------
# GET /api/jobs/{job_id}/download — download generated video
# ---------------------------------------------------------------------------
@router.get("/{job_id}/download")
async def download_video(
    job_id: uuid.UUID,
    session: AsyncSession = Depends(get_session),
) -> FileResponse:
    """Download the generated video file for a completed job."""
    job = await job_service.get_job(session, job_id)
    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Job not found",
        )
    if not job.video_path:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Video not available",
        )

    video_file = Path(job.video_path)
    if not video_file.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Video file not found on disk",
        )

    return FileResponse(
        path=str(video_file),
        media_type="video/mp4",
        filename=f"{job_id}.mp4",
    )


# ---------------------------------------------------------------------------
# POST /api/jobs/{job_id}/upload — worker uploads generated video
# ---------------------------------------------------------------------------
@router.post("/{job_id}/upload")
async def upload_video(
    job_id: uuid.UUID,
    file: UploadFile,
    session: AsyncSession = Depends(get_session),
    _api_key: str = Depends(verify_worker_api_key),
) -> dict:
    """Accept a video file upload from the worker.

    Streams the file to disk in chunks to handle large files without
    loading the entire payload into memory.
    """
    job = await job_service.get_job(session, job_id)
    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Job not found",
        )

    # Ensure the destination directory exists
    video_dir: Path = settings.generated_videos_dir
    video_dir.mkdir(parents=True, exist_ok=True)
    dest = video_dir / f"{job_id}.mp4"

    # Stream to disk in chunks
    try:
        with dest.open("wb") as out:
            while chunk := await file.read(_UPLOAD_CHUNK_SIZE):
                out.write(chunk)
    except Exception as exc:
        logger.exception("Failed to write upload for job %s", job_id)
        # Clean up partial file
        dest.unlink(missing_ok=True)
        await job_service.update_job_status(
            session, job_id, JobStatus.FAILED, error_message=str(exc)
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Failed to store video file",
        ) from exc

    # Update job record
    video_path = str(dest)
    await job_service.set_video_path(session, job_id, video_path)

    logger.info("Stored upload for job %s → %s", job_id, video_path)
    return {"status": "ok", "video_path": f"generated_videos/{job_id}.mp4"}


# ---------------------------------------------------------------------------
# PATCH /api/jobs/{job_id}/status — worker updates job status
# ---------------------------------------------------------------------------
@router.patch("/{job_id}/status", response_model=JobRead)
async def update_job_status(
    job_id: uuid.UUID,
    body: JobStatusUpdate,
    session: AsyncSession = Depends(get_session),
    _api_key: str = Depends(verify_worker_api_key),
) -> JobRead:
    """Update job status from the worker (e.g. GENERATING, UPLOADING, FAILED)."""
    job = await job_service.get_job(session, job_id)
    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Job not found",
        )

    updated = await job_service.update_job_status(
        session,
        job_id,
        body.status,
        error_message=body.error_message,
        generation_time_seconds=body.generation_time_seconds,
    )
    return JobRead.model_validate(updated)
