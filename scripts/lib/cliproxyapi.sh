# CLIProxyAPI, the helper that serves the Codex and Claude subscription targets. Sourced by
# scripts/build-app.sh and scripts/package-app.sh, so the development and the release app bundle
# the same pinned, checksum-verified release.
#
# Bumping the helper is this pin plus a Jarvis release: take the version and the darwin_aarch64
# checksum from checksums.txt at https://github.com/router-for-me/CLIProxyAPI/releases.
CLIPROXYAPI_VERSION="7.3.3"
CLIPROXYAPI_SHA256_ARM64="f142744581a97888425c2e2d728dc3dc1478a02eac314913ec067ae144f7ae78"

# Copy the pinned helper into an assembled app: the binary beside the app's executable, where
# Bundle.url(forAuxiliaryExecutable:) finds it, and its MIT license, which must travel with it. The
# archive is cached under .build and verified on every use, so a corrupted cache fails the build.
bundle_cliproxyapi() {
  local app="$1"
  local cache=".build/cliproxyapi/$CLIPROXYAPI_VERSION"
  local name="CLIProxyAPI_${CLIPROXYAPI_VERSION}_darwin_aarch64.tar.gz"
  local archive="$cache/$name"
  mkdir -p "$cache"
  if [[ ! -f "$archive" ]]; then
    echo "▶ downloading CLIProxyAPI $CLIPROXYAPI_VERSION"
    curl -fsSL --retry 3 -o "$archive.partial" \
      "https://github.com/router-for-me/CLIProxyAPI/releases/download/v$CLIPROXYAPI_VERSION/$name"
    mv "$archive.partial" "$archive"
  fi
  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$CLIPROXYAPI_SHA256_ARM64" ]]; then
    rm -f "$archive"
    echo "error: CLIProxyAPI $CLIPROXYAPI_VERSION archive checksum mismatch (got $actual)" >&2
    return 1
  fi
  local extracted="$cache/extracted"
  rm -rf "$extracted"
  mkdir -p "$extracted"
  tar -xzf "$archive" -C "$extracted" cli-proxy-api LICENSE
  install -m 755 "$extracted/cli-proxy-api" "$app/Contents/MacOS/cliproxyapi"
  mkdir -p "$app/Contents/Resources/Licenses"
  install -m 644 "$extracted/LICENSE" "$app/Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt"
}
