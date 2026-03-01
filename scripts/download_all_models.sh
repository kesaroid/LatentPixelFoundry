#!/usr/bin/env bash
# Download all LTX-2 model files required by the GPU worker.
# Run on the EC2 instance (or any machine with ~100GB free disk).
#
# Usage:
#   ./scripts/download_all_models.sh
#   MODELS_DIR=/path/to/models ./scripts/download_all_models.sh
#
# Uses FP8 checkpoint (~25GB) to fit g5.xlarge memory. Total ~60GB.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
BASE="https://huggingface.co/Lightricks/LTX-2/resolve/main"

mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

echo "Downloading LTX-2 models to $MODELS_DIR"
echo ""

# 1. Distilled LoRA (~1.5GB)
if [ -f "ltx-2-19b-distilled-lora-384.safetensors" ]; then
    echo "  ltx-2-19b-distilled-lora-384.safetensors exists, skipping"
else
    echo "  Downloading distilled LoRA..."
    wget -q --show-progress -O ltx-2-19b-distilled-lora-384.safetensors \
        "$BASE/ltx-2-19b-distilled-lora-384.safetensors"
fi

# 2. Spatial upscaler (HF uses "upscaler", worker expects "upsampler")
if [ -f "ltx-2-spatial-upscaler-x2-1.0.safetensors" ]; then
    echo "  ltx-2-spatial-upscaler-x2-1.0.safetensors exists, skipping"
else
    echo "  Downloading spatial upscaler..."
    wget -q --show-progress -O ltx-2-spatial-upscaler-x2-1.0.safetensors \
        "$BASE/ltx-2-spatial-upscaler-x2-1.0.safetensors"
fi
if [ ! -f "ltx-2-spatial-upsampler-x2-1.0.safetensors" ]; then
    ln -s ltx-2-spatial-upscaler-x2-1.0.safetensors ltx-2-spatial-upsampler-x2-1.0.safetensors
    echo "  Created symlink: upscaler -> upsampler"
fi

# 3. Gemma-3 text encoder
MODELS_DIR="$MODELS_DIR" "$SCRIPT_DIR/download_gemma3.sh"

# 4. Main checkpoint - FP8 (~25GB) for g5.xlarge; use full (~40GB) for larger instances
if [ -f "ltx-2-19b-dev-fp8.safetensors" ]; then
    echo "  ltx-2-19b-dev-fp8.safetensors exists, skipping"
else
    echo "  Downloading FP8 checkpoint (~25GB)..."
    wget -q --show-progress -O ltx-2-19b-dev-fp8.safetensors \
        "$BASE/ltx-2-19b-dev-fp8.safetensors"
fi

echo ""
echo "Done. Models at $MODELS_DIR"
echo ""
echo "Expected layout:"
echo "  ltx-2-19b-dev-fp8.safetensors"
echo "  ltx-2-19b-distilled-lora-384.safetensors"
echo "  ltx-2-spatial-upscaler-x2-1.0.safetensors"
echo "  ltx-2-spatial-upsampler-x2-1.0.safetensors (symlink)"
echo "  gemma-3/"
echo "    tokenizer/       (preprocessor_config.json, tokenizer.json, etc.)"
echo "    text_encoder/    (config.json, model-*.safetensors, etc.)"
