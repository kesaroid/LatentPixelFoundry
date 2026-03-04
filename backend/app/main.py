"""
FastAPI application entry point.

Configures the app with:
- Async lifespan (DB init, generated_videos directory creation)
- CORS middleware for frontend
- Jobs API router
- Health check endpoint
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from backend.app.api.jobs import router as jobs_router
from backend.app.core.config import settings
from backend.app.core.database import init_db
from backend.app.core.logging import get_logger, setup_logging

logger = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup and shutdown logic."""
    setup_logging()
    logger.info("Starting up — initializing database tables")
    await init_db()

    # Ensure the generated_videos directory exists
    videos_dir = settings.generated_videos_dir
    videos_dir.mkdir(parents=True, exist_ok=True)
    logger.info("Generated videos directory: %s", videos_dir.resolve())

    yield

    logger.info("Shutting down")


app = FastAPI(
    title="AI Video Generator — Backend API",
    version="1.0.0",
    lifespan=lifespan,
)

# ---------------------------------------------------------------------------
# CORS — allow the Next.js frontend dev server
# ---------------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Routers
# ---------------------------------------------------------------------------
app.include_router(jobs_router, prefix="/api")


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
@app.get("/health", tags=["health"])
async def health_check() -> dict[str, str]:
    """Simple liveness probe."""
    return {"status": "ok"}
