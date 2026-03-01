#!/usr/bin/env bash
# Download Gemma-3 text encoder from Lightricks/LTX-2 (required by LTX-2 pipeline).
#
# LTX-2 expects this layout (NOT the flat google/gemma-3-1b-it layout):
#   gemma-3/
#     tokenizer/          (preprocessor_config.json, tokenizer.json, etc.)
#     text_encoder/       (config.json, model-*.safetensors, etc.)
#
# Usage:
#   ./scripts/download_gemma3.sh
#   MODELS_DIR=/path/to/models ./scripts/download_gemma3.sh

set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/models}"
DEST="${MODELS_DIR}/gemma-3"
BASE="https://huggingface.co/Lightricks/LTX-2/resolve/main"

# Detect old flat layout (e.g. from google/gemma-3-1b-it snapshot_download)
if [ -d "$DEST" ] && [ -f "$DEST/config.json" ] && [ ! -d "$DEST/tokenizer" ]; then
    echo "ERROR: $DEST has flat layout (config.json in root) but LTX-2 needs tokenizer/ and text_encoder/."
    echo "  Backup and re-run: mv $DEST ${DEST}-backup"
    echo "  Then run this script again."
    exit 1
fi

# Create subdirs first (required; wget does not create parent dirs)
mkdir -p "$DEST/tokenizer" "$DEST/text_encoder"
cd "$DEST" || exit 1

echo "Downloading Gemma-3 text encoder to $DEST (LTX-2 layout: tokenizer/ + text_encoder/)..."

# Tokenizer files
for f in added_tokens.json chat_template.jinja preprocessor_config.json processor_config.json special_tokens_map.json tokenizer.json tokenizer.model tokenizer_config.json; do
    [ -f "tokenizer/$f" ] && echo "  tokenizer/$f exists, skipping" || wget -q --show-progress -O "tokenizer/$f" "$BASE/tokenizer/$f"
done

# Text encoder configs
for f in config.json generation_config.json diffusion_pytorch_model.safetensors.index.json model.safetensors.index.json; do
    [ -f "text_encoder/$f" ] && echo "  text_encoder/$f exists, skipping" || wget -q --show-progress -O "text_encoder/$f" "$BASE/text_encoder/$f"
done

# Text encoder weights (diffusers format)
for i in $(seq -w 1 12); do
    f="text_encoder/diffusion_pytorch_model-000${i}-of-00012.safetensors"
    [ -f "$f" ] && echo "  $f exists, skipping" || wget -q --show-progress -O "$f" "$BASE/text_encoder/diffusion_pytorch_model-000${i}-of-00012.safetensors"
done

# Text encoder weights (transformers format)
for i in $(seq -w 1 11); do
    f="text_encoder/model-000${i}-of-00011.safetensors"
    [ -f "$f" ] && echo "  $f exists, skipping" || wget -q --show-progress -O "$f" "$BASE/text_encoder/model-000${i}-of-00011.safetensors"
done

echo "Done. Gemma-3 text encoder at $DEST"