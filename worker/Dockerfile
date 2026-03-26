# =============================================================================
# GPU Worker Dockerfile — LTX-2 video generation + ComfyUI
# =============================================================================
# Build from project root: docker build -f worker/Dockerfile .
# Runs worker on port 9000 and ComfyUI on port 8188.
# Mount ~/models at /models; set CHECKPOINT_FILENAME, BACKEND_URL.
# =============================================================================

FROM nvidia/cuda:12.1.1-cudnn8-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Python 3.11, pip, git, and supervisord
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip git supervisor \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/python3.11 /usr/bin/python3

WORKDIR /app

# Install Python deps (worker/requirements.txt)
COPY worker/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Worker app + test script (run inside container where torch/diffusers are installed)
COPY worker/main.py worker/pipeline_ltx2.py /app/
COPY worker/scripts/run_prompt.py /app/scripts/run_prompt.py

# ── ComfyUI ──────────────────────────────────────────────────────────────────
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/comfyui \
    && pip install --no-cache-dir -r /opt/comfyui/requirements.txt

# LTX-Video custom nodes
RUN git clone https://github.com/Lightricks/ComfyUI-LTXVideo.git \
        /opt/comfyui/custom_nodes/ComfyUI-LTXVideo \
    && if [ -f /opt/comfyui/custom_nodes/ComfyUI-LTXVideo/requirements.txt ]; then \
        pip install --no-cache-dir -r /opt/comfyui/custom_nodes/ComfyUI-LTXVideo/requirements.txt; \
    fi

COPY worker/extra_model_paths.yaml /opt/comfyui/extra_model_paths.yaml

# ── Process management ───────────────────────────────────────────────────────
COPY worker/supervisord.conf /etc/supervisord.conf
COPY worker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Writable temp dir (avoids "No usable temporary directory" when writing outputs)
RUN mkdir -p /tmp && chmod 1777 /tmp

EXPOSE 9000 8188

CMD ["/entrypoint.sh"]
