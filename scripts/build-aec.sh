#!/usr/bin/env bash
# Build a universal static WebRTC AEC3 library in .build/aec for Intel and release builds.
# Prereqs: brew install meson ninja pkgconf
#
# forcefallback statically links webrtc's wrap-pinned abseil 20240722.0, which still has the
# absl::Nullable/absl::Nonnull aliases its source uses. Homebrew's newer abseil removed them.
set -euo pipefail

WEBRTC_TAG="v2.1"
WEBRTC_COMMIT="846fe90a289f58b7c9303a635142aa2c7caa93e5"
export MACOSX_DEPLOYMENT_TARGET="14.0"
unset PKG_CONFIG_PATH                     # keep Homebrew's incompatible abseil out

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM_CPP="$REPO_ROOT/scripts/aec/jarvis_aec.cpp"
SHIM_HDR="$REPO_ROOT/Sources/CJarvisAEC/include"
OUT_LIB="$REPO_ROOT/.build/aec/libjarvis-aec.a"

WORK="${AEC_WORK:-$REPO_ROOT/.build/aec}"
mkdir -p "$WORK" "$(dirname "$OUT_LIB")"

# Build only the library target: the bundled run-offline demo fails to link.
SOURCE="$WORK/wap-$WEBRTC_TAG"
if [[ ! -d "$SOURCE" ]]; then
  rm -rf "$SOURCE.partial"
  git clone --depth 1 --branch "$WEBRTC_TAG" \
    https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git "$SOURCE.partial"
  mv "$SOURCE.partial" "$SOURCE"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$WEBRTC_COMMIT" ]]; then
  echo "error: WebRTC source does not match the pinned commit" >&2
  exit 1
fi
cd "$SOURCE"
for architecture in arm64 x86_64; do
  cpu_family="$architecture"
  [[ "$architecture" != arm64 ]] || cpu_family=aarch64
  cross_file="$WORK/$architecture.ini"
  cat > "$cross_file" <<EOF
[binaries]
c = ['clang', '-arch', '$architecture']
cpp = ['clang++', '-arch', '$architecture']
ar = 'ar'
strip = 'strip'
[host_machine]
system = 'darwin'
cpu_family = '$cpu_family'
cpu = '$architecture'
endian = 'little'
[properties]
needs_exe_wrapper = true
EOF
  builddir="build-$architecture"
  setup_args=()
  if [[ -f "$builddir/meson-private/coredata.dat" ]]; then
    setup_args+=(--reconfigure)
  fi
  meson setup ${setup_args[@]+"${setup_args[@]}"} "$builddir" --cross-file "$cross_file" \
    --default-library=static --buildtype=release -Dinline-sse=false \
    --wrap-mode=forcefallback \
    -Dc_args="-mmacosx-version-min=14.0" -Dcpp_args="-mmacosx-version-min=14.0" \
    -Dc_link_args="-mmacosx-version-min=14.0" -Dcpp_link_args="-mmacosx-version-min=14.0"
  ninja -C "$builddir" webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a
  WEBRTC_LIB="$SOURCE/$builddir/webrtc/modules/audio_processing/libwebrtc-audio-processing-2.a"
  ABSL_INC="$(find "$SOURCE/subprojects" -maxdepth 1 -type d -name 'abseil-cpp-*' | head -1)"
  clang++ -std=c++17 -arch "$architecture" -O2 -mmacosx-version-min=14.0 -Wno-nullability-completeness \
    -DWEBRTC_LIBRARY_IMPL -DWEBRTC_POSIX -DWEBRTC_MAC \
    -c "$SHIM_CPP" -I"$SOURCE/webrtc" -I"$SHIM_HDR" -I"$ABSL_INC" \
    -o "$WORK/jarvis_aec-$architecture.o"
  libtool -static -o "$WORK/libjarvis-aec-$architecture.a" \
    "$WEBRTC_LIB" "$WORK/jarvis_aec-$architecture.o"
done
lipo -create "$WORK/libjarvis-aec-arm64.a" "$WORK/libjarvis-aec-x86_64.a" -output "$OUT_LIB.partial"
for architecture in arm64 x86_64; do
  lipo "$OUT_LIB.partial" -verify_arch "$architecture"
done

# Git-ignored license copies for cross-checking THIRD_PARTY_NOTICES.md, which is authoritative.
TP="$REPO_ROOT/Sources/CJarvisAEC/third_party"
mkdir -p "$TP/webrtc-audio-processing" "$TP/abseil-cpp"
cp "$SOURCE/COPYING" "$SOURCE/AUTHORS" "$TP/webrtc-audio-processing/" 2>/dev/null || true
cp "$ABSL_INC/LICENSE" "$ABSL_INC/AUTHORS" "$TP/abseil-cpp/" 2>/dev/null || true

# WebRTC's classic VAD symbols stay in the archive: upstream's audio-processing objects depend on them.
nm "$OUT_LIB.partial" > "$WORK/symbols.txt"
if ! grep -q 'T _jarvis_aec_create' "$WORK/symbols.txt"; then
  echo "FAIL: jarvis_aec_create not defined in $OUT_LIB.partial" >&2; exit 1
fi
otool -l "$OUT_LIB.partial" > "$WORK/load-commands.txt"
if grep -E 'minos' "$WORK/load-commands.txt" | grep -v '14.0'; then
  echo "FAIL: some objects target a macOS other than 14.0" >&2; exit 1
fi
mv "$OUT_LIB.partial" "$OUT_LIB"
echo "Built $OUT_LIB ($(du -h "$OUT_LIB" | cut -f1)); shim present, all objects minos 14.0."
echo "sha256: $(shasum -a 256 "$OUT_LIB" | cut -d' ' -f1)"
