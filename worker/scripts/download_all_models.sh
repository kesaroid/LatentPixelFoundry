#!/usr/bin/env bash
# Download LTX-2 and Gemma-3 models to ~/models (Option A from README_RUNTIME.md).
# Run on the EC2 instance. Uses CHECKPOINT_FILENAME and HF_TOKEN from environment.
set -euo pipefail

CHECKPOINT_FILENAME="${CHECKPOINT_FILENAME:-ltx-2-19b-dev-fp8.safetensors}"
HF_BASE="${HF_BASE:-https://huggingface.co/Lightricks/LTX-2/resolve/main}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
LTX2_FILES=(
    "$CHECKPOINT_FILENAME"
    "ltx-2-19b-distilled-lora-384.safetensors"
    "ltx-2-spatial-upscaler-x2-1.0.safetensors"
)
GEMMA_REPO="${GEMMA_REPO:-google/gemma-3-1b-it}"

mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

echo "[download_all_models] LTX-2 files from Hugging Face..."
for f in "${LTX2_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        echo "  $f already exists, skipping."
    else
        echo "  Downloading $f..."
        if [[ -n "${HF_TOKEN:-}" ]]; then
            wget -q --show-progress --header="Authorization: Bearer ${HF_TOKEN}" -O "$f" "${HF_BASE}/${f}"
        else
            wget -q --show-progress -O "$f" "${HF_BASE}/${f}"
        fi
    fi
done

if [[ -f ltx-2-spatial-upscaler-x2-1.0.safetensors && ! -f ltx-2-spatial-upsampler-x2-1.0.safetensors ]]; then
    ln -s ltx-2-spatial-upscaler-x2-1.0.safetensors ltx-2-spatial-upsampler-x2-1.0.safetensors
    echo "  Symlink: upscaler -> upsampler"
fi

echo "[download_all_models] Gemma-3 text encoder..."
if [[ -d gemma-3 && -n "$(ls -A gemma-3 2>/dev/null)" ]]; then
    echo "  gemma-3/ already exists, skipping."
elif [[ -z "${HF_TOKEN:-}" ]]; then
    echo "  HF_TOKEN not set; skipping Gemma-3 (gated model). Set it and re-run to download."
else
    pip3 install -q huggingface_hub 2>/dev/null || true
    python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('${GEMMA_REPO}', local_dir='${MODELS_DIR}/gemma-3', token='${HF_TOKEN}')
print('  Gemma-3 download complete.')
"
fi

echo "[download_all_models] All model files ready."
