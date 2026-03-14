#!/usr/bin/env bash
# Download LTX-2 models to ~/models/ltx2 in Hub structure (what diffusers expects).
# Run on the EC2 instance. Uses CHECKPOINT_FILENAME and HF_TOKEN from environment.
# Pipeline loads from /models/ltx2 with local_files_only=True (no Hub cache).
set -euo pipefail

CHECKPOINT_FILENAME="${CHECKPOINT_FILENAME:-ltx-2-19b-dev-fp8.safetensors}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
LTX2_REPO="Lightricks/LTX-2"
LTX2_DIR="${MODELS_DIR}/ltx2"

mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

echo "[download_all_models] LTX-2 full repo (diffusers layout) to ${LTX2_DIR}..."
if [[ -f "${LTX2_DIR}/model_index.json" ]]; then
    echo "  ltx2/ already has model_index.json, skipping. (Delete ${LTX2_DIR} to re-download.)"
else
    pip3 install -q huggingface_hub 2>/dev/null || true
    # Exclude large checkpoints we don't need (saves ~70GB when using fp8)
    python3 -c "
from huggingface_hub import snapshot_download
import os
checkpoint = os.environ.get('CHECKPOINT_FILENAME', 'ltx-2-19b-dev-fp8.safetensors')
ignore = [
    'ltx-2-19b-dev.safetensors',           # 43GB full precision
    'ltx-2-19b-distilled.safetensors',     # 43GB
    'ltx-2-19b-dev-fp4.safetensors',       # 20GB
    'ltx-2-19b-distilled-fp8.safetensors', # 27GB (we use LoRA, not this)
]
# Keep the checkpoint we want
if checkpoint in ignore:
    ignore.remove(checkpoint)
snapshot_download(
    '${LTX2_REPO}',
    local_dir='${LTX2_DIR}',
    local_dir_use_symlinks=False,
    ignore_patterns=ignore,
    token=os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_API_KEY') or None,
)
print('  LTX-2 download complete.')
"
fi

echo "[download_all_models] All model files ready. Pipeline will load from ${LTX2_DIR}"
