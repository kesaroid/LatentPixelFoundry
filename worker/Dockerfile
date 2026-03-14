# =============================================================================
# GPU Worker Dockerfile — LTX-2 video generation (EC2 g5.xlarge / g5.2xlarge)
# =============================================================================
# Build from project root: docker build -f worker/Dockerfile .
# Runs on port 9000; mount ~/models at /models; set CHECKPOINT_FILENAME, BACKEND_URL.
# =============================================================================

FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Python 3.11 and pip
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3

WORKDIR /app

# Install Python deps (worker/requirements.txt)
COPY worker/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Worker app + test script (run inside container where torch/diffusers are installed)
COPY worker/main.py worker/pipeline_ltx2.py /app/
COPY worker/scripts/run_prompt.py /app/scripts/run_prompt.py

# Writable temp dir (avoids "No usable temporary directory" when writing outputs)
RUN mkdir -p /tmp && chmod 1777 /tmp

EXPOSE 9000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9000"]
