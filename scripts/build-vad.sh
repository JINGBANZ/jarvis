#!/usr/bin/env bash
# Regenerate Sources/JarvisApp/Resources/SileroVAD.mlmodelc, the local voice-activity model used for
# turn detection on the client-commit transcription path. You only need to run this when bumping the
# Silero version; the resulting .mlmodelc is committed so a normal `swift build` needs none of this
# toolchain. Same arrangement as scripts/build-aec.sh.
#
# Prereqs: python3.11 (brew install python@3.11). Everything else is installed into a throwaway venv
# at pinned versions.
#
# Why pin torch: coremltools tracks a specific torch release, and newer torch has shipped graph
# changes that break the conversion outright (a 2.13 trace types the STFT conv stride as a string).
# Pinning both keeps a regenerated model reproducible rather than dependent on install order.
#
# The converter refuses to write the model unless it matches upstream ONNX Runtime on a streaming
# parity run. Since the artifact is committed, that check is the only guard against a silent
# numerical regression reaching production.
set -euo pipefail

SILERO_REV="7e30209a3e90"            # snakers4/silero-vad v6.2.1
TORCH_VERSION="2.7.0"                # newest release coremltools 9 is tested against
COREMLTOOLS_VERSION="9.0"
ONNXRUNTIME_VERSION="1.29.0"
NUMPY_VERSION="2.4.6"           # pinned like the rest: it feeds the parity comparison
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

# 1. Pinned upstream source. The tarball carries both the TorchScript model we convert and the
#    16 kHz ONNX model the parity check runs against, so one pinned revision fixes both sides.
#    The checkout is keyed by revision: a shared "silero" directory would let a bumped SILERO_REV
#    silently convert the previously cached revision, so the committed model would not match the pin.
SILERO_SRC="$WORK/silero-$SILERO_REV"
if [ ! -d "$SILERO_SRC" ]; then
  echo "==> fetching silero-vad @ $SILERO_REV"
  rm -rf "$SILERO_SRC.partial"
  mkdir -p "$SILERO_SRC.partial"
  curl -fsSL "https://github.com/snakers4/silero-vad/archive/${SILERO_REV}.tar.gz" \
    -o "$WORK/silero-$SILERO_REV.tgz"
  tar xzf "$WORK/silero-$SILERO_REV.tgz" -C "$SILERO_SRC.partial" --strip-components=1
  # Publish only after a complete extract, so an interrupted run cannot leave a half-tree that the
  # next run mistakes for a valid cache.
  mv "$SILERO_SRC.partial" "$SILERO_SRC"
fi

# 2. Throwaway venv at pinned versions.
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

# 3. Convert, verify, install.
echo "==> converting"
"$WORK/venv/bin/python" "$CONVERTER" \
  --silero-data "$SILERO_SRC/src/silero_vad/data" \
  --output "$OUT_MODEL"

echo "==> done: ${OUT_MODEL#"$REPO_ROOT"/} ($(du -sh "$OUT_MODEL" | cut -f1))"
