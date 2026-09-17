#!/usr/bin/env bash
# Regenerate the committed Sources/CJarvisAEC/lib/libjarvis-aec.a, a static WebRTC AEC3 library for
# arm64 macOS 14.0 with no dylib dependencies. Run only when bumping webrtc.
# Prereqs: brew install meson ninja pkgconf
#
# forcefallback statically links webrtc's wrap-pinned abseil 20240722.0, which still has the
# absl::Nullable/absl::Nonnull aliases its source uses. Homebrew's newer abseil removed them.
set -euo pipefail

WEBRTC_TAG="v2.1"
export MACOSX_DEPLOYMENT_TARGET="14.0"   # read by meson; the package's macOS floor
unset PKG_CONFIG_PATH                     # keep Homebrew's incompatible abseil out

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_CPP="$REPO_ROOT/scripts/aec/jarvis_aec.cpp"
SHIM_HDR="$REPO_ROOT/Sources/CJarvisAEC/include"
OUT_LIB="$REPO_ROOT/Sources/CJarvisAEC/lib/libjarvis-aec.a"

WORK="${AEC_WORK:-/tmp/jarvis-aec-build}"
mkdir -p "$WORK" "$(dirname "$OUT_LIB")"

# Build only the library target: the bundled run-offline demo fails to link.
if [ ! -d "$WORK/wap" ]; then
  git clone --depth 1 --branch "$WEBRTC_TAG" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$WORK/wap"
fi
cd "$WORK/wap"
meson setup builddir \
  --default-library=static --buildtype=release -Dinline-sse=false \
  --wrap-mode=forcefallback \
  -Dc_args="-mmacosx-version-min=14.0" -Dcpp_args="-mmacosx-version-min=14.0" \
  -Dc_link_args="-mmacosx-version-min=14.0" -Dcpp_link_args="-mmacosx-version-min=14.0" || true
ninja -C builddir webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a
WEBRTC_LIB="$WORK/wap/builddir/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"
# The shim needs abseil headers because webrtc's public headers include absl/.
ABSL_INC="$(find "$WORK/wap/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"

clang++ -std=c++17 -arch arm64 -O2 -mmacosx-version-min=14.0 -Wno-nullability-completeness \
  -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX -DWEBRTC_MAC \
  -c "$SHIM_CPP" -I"$WORK/wap/webrtc" -I"$SHIM_HDR" -I"$ABSL_INC" \
  -o "$WORK/jarvis_aec.o"

# The webrtc archive already contains the static abseil objects.
libtool -static -o "$OUT_LIB" "$WEBRTC_LIB" "$WORK/jarvis_aec.o"

# Git-ignored license copies for cross-checking THIRD_PARTY_NOTICES.md, which is authoritative.
TP="$REPO_ROOT/Sources/CJarvisAEC/third_party"
mkdir -p "$TP/webrtc-audio-processing" "$TP/abseil-cpp"
cp "$WORK/wap/COPYING" "$WORK/wap/AUTHORS" "$TP/webrtc-audio-processing/" 2>/dev/null || true
cp "$ABSL_INC/LICENSE" "$ABSL_INC/AUTHORS" "$TP/abseil-cpp/" 2>/dev/null || true

# WebRTC's classic VAD symbols stay in the archive: upstream's audio-processing objects depend on them.
if ! nm "$OUT_LIB" 2>/dev/null | grep -q 'T _jarvis_aec_create'; then
  echo "FAIL: jarvis_aec_create not defined in $OUT_LIB" >&2; exit 1
fi
if otool -l "$OUT_LIB" 2>/dev/null | grep -E 'minos' | grep -vq '14.0'; then
  echo "FAIL: some objects target a macOS other than 14.0" >&2; exit 1
fi
# The checksum ties the committed binary back to a rebuild.
echo "Built $OUT_LIB ($(du -h "$OUT_LIB" | cut -f1)); shim present, all objects minos 14.0."
echo "sha256: $(shasum -a 256 "$OUT_LIB" | cut -d' ' -f1)"
