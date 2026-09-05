#!/usr/bin/env bash
# Convert stabilityai/sd-turbo (distilled SD 2.1, 2-4 steps, no CFG) to
# MiniVid's Core ML model format: a compiled Resources/ folder
# (TextEncoder.mlmodelc, Unet.mlmodelc, VAEDecoder/Encoder.mlmodelc,
# vocab/merges), palettized to 6 bits, SPLIT_EINSUM attention for the
# Neural Engine — the exact same layout as Apple's downloadable models.
#
# Needs: uv, ~10 GB free disk, ~16 GB RAM, 30-60 min.
# Output: build/sd-turbo-out/Resources + minivid-sd-turbo zip.
#
# License note: sd-turbo weights are under the Stability AI Non-Commercial
# Research Community License — fine for personal/portfolio use, not for a
# commercial App Store release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build"
VENV="$WORK/convert-venv"
OUT="$WORK/sd-turbo-out"
ZIPNAME="minivid-sd-turbo_split_einsum_compiled"

mkdir -p "$WORK"

if [ ! -x "$VENV/bin/python" ]; then
    uv venv --python 3.11 "$VENV"
    uv pip install --python "$VENV/bin/python" \
        "git+https://github.com/apple/ml-stable-diffusion@1.1.1"
fi

"$VENV/bin/python" -m python_coreml_stable_diffusion.torch2coreml \
    --model-version stabilityai/sd-turbo \
    --convert-unet \
    --convert-text-encoder \
    --convert-vae-decoder \
    --convert-vae-encoder \
    --attention-implementation SPLIT_EINSUM \
    --quantize-nbits 6 \
    --bundle-resources-for-swift-cli \
    -o "$OUT"

# Package like Apple's zips: one folder containing the compiled resources.
STAGE="$WORK/$ZIPNAME"
rm -rf "$STAGE" "$WORK/$ZIPNAME.zip"
mkdir -p "$STAGE"
cp -R "$OUT/Resources/." "$STAGE/"
(cd "$WORK" && zip -r -q "$ZIPNAME.zip" "$ZIPNAME")

echo "Done:"
echo "  folder → $STAGE"
echo "  zip    → $WORK/$ZIPNAME.zip"
echo "Install: drop the folder into MiniVid/Models via the Files app (or the"
echo "Mac container), then 'Re-scan Models folder' in the app."
