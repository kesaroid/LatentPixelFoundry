# ============================================================================
# Backend Dockerfile — ARM-compatible (M1 / ARM64)
# ============================================================================
# python:3.11-slim supports linux/arm64 natively, so this image builds and
# runs on M1 MacBook Air without emulation.
#
# Build context must be the PROJECT ROOT (not ./backend) so that the
# "backend" package prefix resolves correctly for imports like:
#     from backend.app.core.config import settings
#
# In docker-compose: context: .   dockerfile: backend/Dockerfile
# ============================================================================

FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Install dependencies (from backend/requirements.txt)
COPY backend/requirements.txt /app/backend/requirements.txt
RUN pip install --no-cache-dir -r /app/backend/requirements.txt

# Copy the backend package
COPY backend/ /app/backend/

# Create the generated_videos directory (config default: "generated_videos" → /app/generated_videos)
RUN mkdir -p /app/generated_videos

EXPOSE 8000

# uvicorn resolves "backend.app.main:app" from WORKDIR=/app
CMD ["uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
