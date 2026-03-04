"""
Mock worker — simulates the GPU worker lifecycle for local M1 development.

Instead of calling a real cloud GPU endpoint, this module:
1. Sleeps to simulate generation time
2. Creates a minimal valid MP4 test file
3. Writes the file directly to generated_videos/
4. Updates job status through each lifecycle stage via direct DB access

This avoids the backend needing to HTTP-call its own upload endpoint.
"""

from __future__ import annotations

import asyncio
import struct
import time
import uuid
from pathlib import Path

from backend.app.core.config import settings
from backend.app.core.database import async_session_factory
from backend.app.core.logging import get_logger
from backend.app.models.job import JobStatus
from backend.app.services import job_service

logger = get_logger(__name__)


def _generate_minimal_mp4() -> bytes:
    """Generate the smallest valid MP4 file (ftyp + moov boxes).

    This produces a ~200-byte file that most players and browsers
    recognize as a valid (but empty) MP4 container.
    """
    # ftyp box: file type declaration
    ftyp_data = b"isom" + b"\x00\x00\x02\x00" + b"isomiso2mp41"
    ftyp_box = struct.pack(">I", 8 + len(ftyp_data)) + b"ftyp" + ftyp_data

    # Minimal moov box with a single mvhd atom
    mvhd_data = (
        b"\x00"  # version
        b"\x00\x00\x00"  # flags
        + b"\x00\x00\x00\x00"  # creation_time
        + b"\x00\x00\x00\x00"  # modification_time
        + struct.pack(">I", 1000)  # timescale
        + struct.pack(">I", 0)  # duration
        + b"\x00\x01\x00\x00"  # rate (1.0)
        + b"\x01\x00"  # volume (1.0)
        + b"\x00" * 10  # reserved
        + b"\x00\x01\x00\x00" + b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00"  # matrix
        + b"\x00\x00\x00\x00" + b"\x00\x01\x00\x00" + b"\x00\x00\x00\x00"
        + b"\x00\x00\x00\x00" + b"\x00\x00\x00\x00" + b"\x40\x00\x00\x00"
        + b"\x00" * 24  # pre_defined
        + struct.pack(">I", 2)  # next_track_ID
    )
    mvhd_box = struct.pack(">I", 8 + len(mvhd_data)) + b"mvhd" + mvhd_data
    moov_box = struct.pack(">I", 8 + len(mvhd_box)) + b"moov" + mvhd_box

    return ftyp_box + moov_box


async def run_mock_worker(job_id: uuid.UUID) -> None:
    """Simulate the full worker lifecycle for a single job.

    This runs as an asyncio task spawned by the worker trigger service.
    """
    logger.info("Mock worker started for job %s", job_id)
    start = time.monotonic()

    try:
        # --- GENERATING ---
        async with async_session_factory() as session:
            await job_service.update_job_status(
                session, job_id, JobStatus.GENERATING
            )

        # Simulate generation delay
        await asyncio.sleep(settings.mock_delay_seconds)
        generation_time = time.monotonic() - start

        # --- UPLOADING ---
        async with async_session_factory() as session:
            await job_service.update_job_status(
                session, job_id, JobStatus.UPLOADING
            )

        # Generate dummy MP4 and write to disk
        video_bytes = _generate_minimal_mp4()
        video_dir: Path = settings.generated_videos_dir
        video_dir.mkdir(parents=True, exist_ok=True)
        video_path = video_dir / f"{job_id}.mp4"
        video_path.write_bytes(video_bytes)

        # --- COMPLETED ---
        async with async_session_factory() as session:
            job = await job_service.set_video_path(
                session, job_id, str(video_path)
            )
            # Also record generation time
            await job_service.update_job_status(
                session,
                job_id,
                JobStatus.COMPLETED,
                generation_time_seconds=round(generation_time, 2),
            )

        logger.info(
            "Mock worker completed job %s in %.1fs — file: %s",
            job_id,
            generation_time,
            video_path,
        )

    except Exception:
        logger.exception("Mock worker failed for job %s", job_id)
        try:
            async with async_session_factory() as session:
                await job_service.update_job_status(
                    session,
                    job_id,
                    JobStatus.FAILED,
                    error_message="Mock worker encountered an error",
                )
        except Exception:
            logger.exception("Failed to mark job %s as FAILED", job_id)
