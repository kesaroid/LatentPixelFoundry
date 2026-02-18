"""
Shared API dependencies.

- Worker API key verification for worker -> backend endpoints.
- Database session dependency (re-exported for convenience).
"""

from __future__ import annotations

from fastapi import Header, HTTPException, status

from backend.app.core.config import settings
from backend.app.core.database import get_session  # noqa: F401 — re-export


async def verify_worker_api_key(
    x_worker_api_key: str = Header(..., alias="X-Worker-API-Key"),
) -> str:
    """Validate the X-Worker-API-Key header matches the configured secret.

    Raises:
        HTTPException 401 if the key is missing or invalid.

    Returns:
        The validated API key string.
    """
    if x_worker_api_key != settings.worker_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
        )
    return x_worker_api_key
