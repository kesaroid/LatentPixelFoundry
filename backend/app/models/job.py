"""
Job model — the central data contract shared across all components.

This module defines the Job table schema and the JobStatus state machine.
The worker communicates status transitions via HTTP; the frontend reads
job records via the backend API.

State Machine:
    PENDING -> TRIGGERED -> GENERATING -> UPLOADING -> COMPLETED
                                                   \-> FAILED
    Any state can transition to FAILED on error.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime, timezone
from typing import Optional

from sqlmodel import Column, DateTime, Enum, Field, SQLModel, text


class JobStatus(str, enum.Enum):
    """Job lifecycle states."""

    PENDING = "PENDING"
    TRIGGERED = "TRIGGERED"
    GENERATING = "GENERATING"
    UPLOADING = "UPLOADING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"


class JobBase(SQLModel):
    """Shared fields for create / read operations."""

    prompt: str = Field(..., min_length=1, max_length=2000, description="Text prompt for video generation")
    duration: int = Field(default=5, ge=1, le=30, description="Video duration in seconds")
    resolution: str = Field(default="720p", description="Video resolution (e.g. 720p, 1080p)")


class Job(JobBase, table=True):
    """Persisted Job record in PostgreSQL."""

    __tablename__ = "jobs"

    id: uuid.UUID = Field(
        default_factory=uuid.uuid4,
        primary_key=True,
        sa_column_kwargs={"server_default": text("gen_random_uuid()")},
    )
    status: JobStatus = Field(
        default=JobStatus.PENDING,
        sa_column=Column(Enum(JobStatus, name="job_status", create_constraint=True), nullable=False),
    )
    video_path: Optional[str] = Field(default=None, description="Local path to generated video")
    generation_time_seconds: Optional[float] = Field(default=None, description="Time taken to generate video")
    error_message: Optional[str] = Field(default=None, max_length=4000, description="Error details if FAILED")
    created_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    updated_at: datetime = Field(
        default_factory=lambda: datetime.now(timezone.utc),
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )


# ---------------------------------------------------------------------------
# Pydantic schemas for API request / response (used by backend & frontend)
# ---------------------------------------------------------------------------


class JobCreate(JobBase):
    """Request body for POST /api/jobs."""

    pass


class JobRead(JobBase):
    """Response schema returned by all job endpoints."""

    id: uuid.UUID
    status: JobStatus
    video_path: Optional[str] = None
    generation_time_seconds: Optional[float] = None
    error_message: Optional[str] = None
    created_at: datetime
    updated_at: datetime


class JobStatusUpdate(SQLModel):
    """Request body for PATCH /api/jobs/{id}/status (worker -> backend)."""

    status: JobStatus
    error_message: Optional[str] = None
    generation_time_seconds: Optional[float] = None
