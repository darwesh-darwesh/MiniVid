#!/usr/bin/env bash
# Download + unzip Apple's palettized Core ML Stable Diffusion 2.1 model into
# ./models (git-ignored). Useful for the iOS Simulator or local inspection.
# Usage: ./scripts/download_model.sh [split_einsum_v2|original]
set -euo pipefail

VARIANT="${1:-split_einsum_v2}"
BASE="https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main"
FILE="coreml-stable-diffusion-2-1-base-palettized_${VARIANT}_compiled.zip"
DEST="$(cd "$(dirname "$0")/.." && pwd)/models"

mkdir -p "$DEST"
echo "Downloading $FILE (~1.2 GB) → $DEST"
curl -L --progress-bar -o "$DEST/$FILE" "$BASE/$FILE"
unzip -o -q "$DEST/$FILE" -d "$DEST"
rm "$DEST/$FILE"
echo "Done. Model resources: $DEST"
