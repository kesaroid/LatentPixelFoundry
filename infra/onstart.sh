#!/bin/bash
# =============================================================================
# infra/onstart.sh — Vast.ai instance onstart script
# =============================================================================
# With --ssh launch mode, Vast.ai *replaces* the image entrypoint, so the
# ComfyUI template's setup (which would create /workspace/ComfyUI) never runs.
# This script bootstraps ComfyUI when missing, installs ComfyUI-LTXVideo, and
# starts ComfyUI on port 8188.
# =============================================================================

set -euo pipefail

COMFY_DIR="/workspace/ComfyUI"
COMFY_REPO="https://github.com/comfyorg/ComfyUI.git"
LTX_REPO="https://github.com/Lightricks/ComfyUI-LTXVideo.git"

mkdir -p /workspace
cd /workspace

# -----------------------------------------------------------------------------
# Bootstrap ComfyUI if the template did not (e.g. entrypoint replaced by --ssh)
# -----------------------------------------------------------------------------
if [[ ! -f "${COMFY_DIR}/main.py" ]]; then
    echo "[lpf] ComfyUI not found; bootstrapping from ${COMFY_REPO}..."
    if [[ -d "$COMFY_DIR" ]]; then
        rm -rf "$COMFY_DIR"
    fi
    git clone --depth 1 "$COMFY_REPO" "$COMFY_DIR"
    cd "$COMFY_DIR"
    pip install -r requirements.txt
    echo "[lpf] ComfyUI installed."
    cd /workspace
fi

CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
LTX_DIR="${CUSTOM_NODES}/ComfyUI-LTXVideo"
mkdir -p "$CUSTOM_NODES"

# -----------------------------------------------------------------------------
# Install or update ComfyUI-LTXVideo custom node
# -----------------------------------------------------------------------------
if [[ ! -d "$LTX_DIR" ]]; then
    echo "[lpf] Installing ComfyUI-LTXVideo custom node..."
    cd "$CUSTOM_NODES"
    git clone --depth 1 "$LTX_REPO"
    cd ComfyUI-LTXVideo
    pip install -r requirements.txt
    echo "[lpf] ComfyUI-LTXVideo installed."
else
    echo "[lpf] ComfyUI-LTXVideo already installed, pulling latest..."
    cd "$LTX_DIR"
    git pull --ff-only 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Start ComfyUI on 8188 if not already listening
# -----------------------------------------------------------------------------
if ! ss -tlnp 2>/dev/null | grep -q ':8188 '; then
    echo "[lpf] Starting ComfyUI on port 8188..."
    (cd "$COMFY_DIR" && nohup python main.py --listen 0.0.0.0 --port 8188 > /tmp/comfyui.log 2>&1 &)
fi

echo "[lpf] Onstart complete."
