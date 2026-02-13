# =============================================================================
# GPU Worker Dockerfile — CUDA 12.1 / Python 3.11 / x86_64 ONLY
# =============================================================================
#
# This image is designed for cloud GPU instances (NVIDIA).
# It is NOT compatible with ARM64 / Apple Silicon.
#
# Build:
#   docker build --platform linux/amd64 -t videogen-worker -f worker/Dockerfile .
#
# Run (requires NVIDIA Container Toolkit):
#   docker run --gpus all -p 9000:9000 --env-file .env videogen-worker
# =============================================================================

FROM --platform=linux/amd64 nvidia/cuda:12.1.1-runtime-ubuntu22.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System dependencies + Python 3.11 via deadsnakes PPA
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        curl \
        ffmpeg \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 \
        python3.11-venv \
        python3.11-distutils \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Python dependencies
# ---------------------------------------------------------------------------
WORKDIR /app

COPY worker/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Application code
# ---------------------------------------------------------------------------
COPY worker/ /app/worker/

# ---------------------------------------------------------------------------
# Runtime configuration
# ---------------------------------------------------------------------------
ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

EXPOSE 9000

# Health check for container orchestration
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:9000/health || exit 1

CMD ["python", "-m", "uvicorn", "worker.worker:app", "--host", "0.0.0.0", "--port", "9000"]
