#!/usr/bin/env bash
# Regenerate the committed Sources/JarvisApp/Resources/SileroVAD.mlmodelc. Run only when bumping Silero.
# Prereqs: python3.11 (brew install python@3.11)
#
# torch is pinned because newer releases break the coremltools conversion. The converter's ONNX
# Runtime parity check is the only guard against a silent numerical regression in the committed model.
set -euo pipefail

SILERO_REV="7e30209a3e90"            # snakers4/silero-vad v6.2.1
TORCH_VERSION="2.7.0"                # newest release coremltools 9 is tested against
COREMLTOOLS_VERSION="9.0"
ONNXRUNTIME_VERSION="1.29.0"
NUMPY_VERSION="2.4.6"           # it feeds the parity comparison
PYTHON_BIN="${PYTHON_BIN:-python3.11}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_MODEL="$REPO_ROOT/Sources/JarvisApp/Resources/SileroVAD.mlmodelc"
CONVERTER="$REPO_ROOT/scripts/vad/convert_silero.py"

WORK="${VAD_WORK:-/tmp/jarvis-vad-build}"
mkdir -p "$WORK"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "error: $PYTHON_BIN not found. brew install python@3.11" >&2
  exit 1
fi

# Keyed by revision so a bumped SILERO_REV never converts a stale cached checkout.
SILERO_SRC="$WORK/silero-$SILERO_REV"
if [ ! -d "$SILERO_SRC" ]; then
  echo "==> fetching silero-vad @ $SILERO_REV"
  rm -rf "$SILERO_SRC.partial"
  mkdir -p "$SILERO_SRC.partial"
  curl -fsSL "https://github.com/snakers4/silero-vad/archive/${SILERO_REV}.tar.gz" \
    -o "$WORK/silero-$SILERO_REV.tgz"
  tar xzf "$WORK/silero-$SILERO_REV.tgz" -C "$SILERO_SRC.partial" --strip-components=1
  # Rename only after a complete extract, so an interrupted run leaves no half-tree cache.
  mv "$SILERO_SRC.partial" "$SILERO_SRC"
fi

if [ ! -x "$WORK/venv/bin/python" ]; then
  echo "==> creating venv"
  "$PYTHON_BIN" -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet --upgrade pip
fi
echo "==> installing pinned conversion toolchain"
"$WORK/venv/bin/pip" install --quiet \
  "torch==$TORCH_VERSION" \
  "coremltools==$COREMLTOOLS_VERSION" \
  "onnxruntime==$ONNXRUNTIME_VERSION" \
  "numpy==$NUMPY_VERSION"

echo "==> converting"
"$WORK/venv/bin/python" "$CONVERTER" \
  --silero-data "$SILERO_SRC/src/silero_vad/data" \
  --output "$OUT_MODEL"

echo "==> done: ${OUT_MODEL#"$REPO_ROOT"/} ($(du -sh "$OUT_MODEL" | cut -f1))"
