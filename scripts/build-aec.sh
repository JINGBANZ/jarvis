#!/usr/bin/env bash
# Regenerate Sources/CJarvisAEC/lib/libjarvis-aec.a — a self-contained static
# WebRTC AEC3 library for arm64 macOS (deployment target 14.0) with ZERO runtime
# dylib dependencies. You only need to run this when bumping the webrtc version;
# the resulting .a is committed so a normal `swift build` needs none of this
# toolchain.  Prereqs (Homebrew):  brew install meson ninja pkgconf
#
# Why forcefallback: webrtc-audio-processing v2.1 ships an abseil subproject wrap
# pinned to 20240722.0 (the LTS that still has the absl::Nullable/absl::Nonnull
# template aliases its source uses). Forcing the fallback makes meson build and
# STATICALLY LINK that abseil straight into libwebrtc-audio-processing-2.a, so
# compile-time and link-time abseil are the identical inline namespace and the
# merge is just "webrtc lib + our shim". Picking up Homebrew's newer abseil
# (which removed those aliases) instead is what breaks the build, so we keep it
# out with `unset PKG_CONFIG_PATH`.
set -euo pipefail

WEBRTC_TAG="v2.1"
export MACOSX_DEPLOYMENT_TARGET="14.0"   # meson reads this; matches the package's macOS floor
unset PKG_CONFIG_PATH                     # keep Homebrew abseil 20260107.1 (incompatible) out

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_CPP="$REPO_ROOT/scripts/aec/jarvis_aec.cpp"
SHIM_HDR="$REPO_ROOT/Sources/CJarvisAEC/include"
OUT_LIB="$REPO_ROOT/Sources/CJarvisAEC/lib/libjarvis-aec.a"

WORK="${AEC_WORK:-/tmp/jarvis-aec-build}"
mkdir -p "$WORK" "$(dirname "$OUT_LIB")"

# 1. webrtc-audio-processing STATIC (AEC3) with its bundled, version-matched abseil.
#    Build only the lib target; the bundled run-offline demo fails to link — ignore it.
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
# Bundled abseil headers are needed only to COMPILE the shim (the webrtc public
# headers include absl/...); the exact subproject dir is version-pinned by the wrap.
ABSL_INC="$(find "$WORK/wap/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"

# 2. Compile our C shim against the webrtc + matching bundled abseil headers.
clang++ -std=c++17 -arch arm64 -O2 -mmacosx-version-min=14.0 -Wno-nullability-completeness \
  -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX -DWEBRTC_MAC \
  -c "$SHIM_CPP" -I"$WORK/wap/webrtc" -I"$SHIM_HDR" -I"$ABSL_INC" \
  -o "$WORK/jarvis_aec.o"

# 3. Merge the webrtc lib (already contains the static abseil objects) + our shim.
libtool -static -o "$OUT_LIB" "$WEBRTC_LIB" "$WORK/jarvis_aec.o"

# 3b. Vendor the exact upstream license files for the statically-linked deps (BSD-3 webrtc,
#     Apache-2.0 abseil), so THIRD_PARTY_NOTICES.md is backed by the real texts at the built versions.
TP="$REPO_ROOT/Sources/CJarvisAEC/third_party"
mkdir -p "$TP/webrtc-audio-processing" "$TP/abseil-cpp"
cp "$WORK/wap/COPYING" "$WORK/wap/AUTHORS" "$TP/webrtc-audio-processing/" 2>/dev/null || true
cp "$ABSL_INC/LICENSE" "$ABSL_INC/AUTHORS" "$TP/abseil-cpp/" 2>/dev/null || true

# 4. Verify the shim symbols are DEFINED and nothing targets a newer macOS than 14.
if ! nm "$OUT_LIB" 2>/dev/null | grep -q 'T _jarvis_aec_create'; then
  echo "FAIL: jarvis_aec_create not defined in $OUT_LIB" >&2; exit 1
fi
if otool -l "$OUT_LIB" 2>/dev/null | grep -E 'minos' | grep -vq '14.0'; then
  echo "FAIL: some objects target a macOS other than 14.0" >&2; exit 1
fi
# 5. Record the artifact checksum so the committed binary can be tied back to a rebuild.
#    (For stricter reproducibility, pin WEBRTC_TAG to a full commit SHA via `git checkout <sha>`.)
echo "Built $OUT_LIB ($(du -h "$OUT_LIB" | cut -f1)); shim present, all objects minos 14.0."
echo "sha256: $(shasum -a 256 "$OUT_LIB" | cut -d' ' -f1)"
