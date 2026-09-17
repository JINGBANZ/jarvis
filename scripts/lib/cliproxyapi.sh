# The pinned CLIProxyAPI subscription helper, shared by build-app.sh and package-app.sh.
# To bump, take the version and darwin_aarch64 checksum from checksums.txt at
# https://github.com/router-for-me/CLIProxyAPI/releases.
CLIPROXYAPI_VERSION="7.3.3"
CLIPROXYAPI_SHA256_ARM64="f142744581a97888425c2e2d728dc3dc1478a02eac314913ec067ae144f7ae78"

# The binary goes in Contents/MacOS for Bundle.url(forAuxiliaryExecutable:), and its MIT license
# must ship with it. The cached archive is re-verified on every use.
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
