"""
HTTP client for communicating with the backend API.

Handles:
- Job status updates (PATCH /api/jobs/{job_id}/status)
- Video file uploads  (POST  /api/jobs/{job_id}/upload)

All requests include the shared X-Worker-API-Key header.
Retry logic with exponential backoff for transient failures.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Optional

import httpx

from worker.config import settings

logger = logging.getLogger(__name__)

# HTTP status codes that warrant a retry
_RETRYABLE_STATUS_CODES = {502, 503, 504, 408, 429}


class BackendClient:
    """Async HTTP client for backend callbacks."""

    def __init__(self, base_url: str | None = None) -> None:
        """Initialize with optional base URL override (e.g. from request payload)."""
        self._base_url = (base_url or settings.backend_url).rstrip("/")
        self._headers = {"X-Worker-API-Key": settings.worker_api_key}
        self._max_retries = settings.max_retries
        self._retry_delay = settings.retry_delay
        self._upload_timeout = settings.upload_timeout

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def update_status(
        self,
        job_id: str,
        status: str,
        *,
        error_message: Optional[str] = None,
        generation_time_seconds: Optional[float] = None,
    ) -> None:
        """Update job status on the backend.

        Calls PATCH /api/jobs/{job_id}/status with the given status
        and optional metadata fields.
        """
        url = f"{self._base_url}/api/jobs/{job_id}/status"
        payload: dict = {"status": status}
        if error_message is not None:
            payload["error_message"] = error_message
        if generation_time_seconds is not None:
            payload["generation_time_seconds"] = generation_time_seconds

        await self._request_with_retry(
            method="PATCH",
            url=url,
            json=payload,
            timeout=30.0,
            context=f"status update to {status}",
        )

    async def upload_video(self, job_id: str, file_path: Path) -> None:
        """Upload a generated video file to the backend.

        Calls POST /api/jobs/{job_id}/upload with the video as
        streaming multipart form data.
        """
        url = f"{self._base_url}/api/jobs/{job_id}/upload"
        file_path = Path(file_path)

        if not file_path.exists():
            raise FileNotFoundError(f"Video file not found: {file_path}")

        file_size_mb = file_path.stat().st_size / (1024 * 1024)
        logger.info(
            "Uploading video for job %s (%.1f MB) to %s",
            job_id,
            file_size_mb,
            url,
        )

        await self._upload_with_retry(
            url=url,
            file_path=file_path,
            context="video upload",
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _request_with_retry(
        self,
        method: str,
        url: str,
        *,
        json: dict | None = None,
        timeout: float = 30.0,
        context: str = "",
    ) -> httpx.Response:
        """Execute an HTTP request with exponential-backoff retry."""
        last_exc: BaseException | None = None

        for attempt in range(1, self._max_retries + 1):
            try:
                async with httpx.AsyncClient(timeout=timeout) as client:
                    resp = await client.request(
                        method,
                        url,
                        headers=self._headers,
                        json=json,
                    )

                if resp.status_code < 400:
                    logger.info(
                        "%s succeeded (attempt %d): %s %s -> %d",
                        context,
                        attempt,
                        method,
                        url,
                        resp.status_code,
                    )
                    return resp

                if resp.status_code in _RETRYABLE_STATUS_CODES:
                    logger.warning(
                        "%s got retryable %d (attempt %d/%d)",
                        context,
                        resp.status_code,
                        attempt,
                        self._max_retries,
                    )
                    last_exc = httpx.HTTPStatusError(
                        f"HTTP {resp.status_code}",
                        request=resp.request,
                        response=resp,
                    )
                else:
                    # Non-retryable error (4xx etc.)
                    logger.error(
                        "%s failed with non-retryable %d: %s",
                        context,
                        resp.status_code,
                        resp.text[:500],
                    )
                    resp.raise_for_status()

            except (httpx.ConnectError, httpx.TimeoutException) as exc:
                logger.warning(
                    "%s connection error (attempt %d/%d): %s",
                    context,
                    attempt,
                    self._max_retries,
                    exc,
                )
                last_exc = exc

            if attempt < self._max_retries:
                delay = self._retry_delay * (2 ** (attempt - 1))
                logger.info("Retrying %s in %.1fs...", context, delay)
                await asyncio.sleep(delay)

        raise RuntimeError(
            f"{context} failed after {self._max_retries} attempts"
        ) from last_exc

    async def _upload_with_retry(
        self,
        url: str,
        file_path: Path,
        *,
        context: str = "",
    ) -> httpx.Response:
        """Upload a file via multipart form with retry."""
        last_exc: BaseException | None = None

        for attempt in range(1, self._max_retries + 1):
            try:
                async with httpx.AsyncClient(
                    timeout=httpx.Timeout(
                        connect=10.0,
                        read=self._upload_timeout,
                        write=self._upload_timeout,
                        pool=10.0,
                    ),
                ) as client:
                    with open(file_path, "rb") as f:
                        files = {"file": (file_path.name, f, "video/mp4")}
                        resp = await client.post(
                            url,
                            headers=self._headers,
                            files=files,
                        )

                if resp.status_code < 400:
                    logger.info(
                        "%s succeeded (attempt %d): POST %s -> %d",
                        context,
                        attempt,
                        url,
                        resp.status_code,
                    )
                    return resp

                if resp.status_code in _RETRYABLE_STATUS_CODES:
                    logger.warning(
                        "%s got retryable %d (attempt %d/%d)",
                        context,
                        resp.status_code,
                        attempt,
                        self._max_retries,
                    )
                    last_exc = httpx.HTTPStatusError(
                        f"HTTP {resp.status_code}",
                        request=resp.request,
                        response=resp,
                    )
                else:
                    logger.error(
                        "%s failed with non-retryable %d: %s",
                        context,
                        resp.status_code,
                        resp.text[:500],
                    )
                    resp.raise_for_status()

            except (httpx.ConnectError, httpx.TimeoutException) as exc:
                logger.warning(
                    "%s connection error (attempt %d/%d): %s",
                    context,
                    attempt,
                    self._max_retries,
                    exc,
                )
                last_exc = exc

            if attempt < self._max_retries:
                delay = self._retry_delay * (2 ** (attempt - 1))
                logger.info("Retrying %s in %.1fs...", context, delay)
                await asyncio.sleep(delay)

        raise RuntimeError(
            f"{context} failed after {self._max_retries} attempts"
        ) from last_exc
