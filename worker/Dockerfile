# =============================================================================
# GPU Worker Dockerfile — CUDA 12.4 / Python 3.11 / x86_64 ONLY
# =============================================================================
#
# This image is designed for cloud GPU instances (NVIDIA).
# It is NOT compatible with ARM64 / Apple Silicon.
#
# Build:
#   docker build --platform linux/amd64 -t videogen-worker -f worker/Dockerfile .
#
# Run (requires NVIDIA Container Toolkit + model files mounted at /models):
#   docker run --gpus all -p 9000:9000 --env-file .env \
#     -v /path/to/models:/models videogen-worker
#
# Expected /models layout:
#   /models/
#     ltx-2-19b-dev.safetensors
#     ltx-2-19b-distilled-lora-384.safetensors
#     ltx-2-spatial-upsampler-x2-1.0.safetensors
#     gemma-3/
#       (all Gemma 3 model files)
# =============================================================================

FROM --platform=linux/amd64 nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System dependencies + Python 3.11 via deadsnakes PPA
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
        curl \
        git \
        ffmpeg \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.11 \
        python3.11-venv \
        python3.11-dev \
        python3.11-distutils \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.11 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# LTX-2 model packages (installed from source)
# ---------------------------------------------------------------------------
WORKDIR /opt

RUN git clone --depth 1 https://github.com/Lightricks/LTX-2.git

RUN pip install --no-cache-dir uv-build \
    && pip install --no-cache-dir \
        -e /opt/LTX-2/packages/ltx-core \
        -e /opt/LTX-2/packages/ltx-pipelines

# ---------------------------------------------------------------------------
# Worker-specific Python dependencies
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
ENV PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

VOLUME ["/models"]

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -f http://localhost:9000/health || exit 1

CMD ["python", "-m", "uvicorn", "worker.worker:app", "--host", "0.0.0.0", "--port", "9000"]
