# The pinned CLIProxyAPI subscription helper, shared by build-app.sh and package-app.sh.
# To bump, take the version and darwin_aarch64 checksum from checksums.txt at
# https://github.com/router-for-me/CLIProxyAPI/releases.
CLIPROXYAPI_VERSION="8.0.20"
CLIPROXYAPI_SHA256_ARM64="abb68051528506076561298ae3c4f3797c360f1d37127c2e459afdecce454df0"

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
