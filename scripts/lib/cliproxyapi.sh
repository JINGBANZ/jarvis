# The same source and local patch supply development and release bundles.
CLIPROXYAPI_VERSION="8.1.0"
CLIPROXYAPI_SOURCE_SHA256="cd784e7846d33805c74e2912b3166c6de705f674e8d766a0c15608b30675343b"
CLIPROXYAPI_GO_VERSION="1.26.10"
CLIPROXYAPI_GO_SHA256="0b5183492292ada170f9b561a834863808dd02edba599e4ad0e89899330020b3"
CLIPROXYAPI_GO_AMD64_SHA256="e820ab780c273ae4a340b79d0f3c4313b74ee029aa3874792145d44b9f4f91da"

cliproxyapi_download() {
  local url="$1" archive="$2" expected="$3"
  if [[ ! -f "$archive" ]]; then
    curl -fsSL --retry 3 -o "$archive.partial" "$url"
    mv "$archive.partial" "$archive"
  fi
  if [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$expected" ]]; then
    rm -f "$archive"
    echo "error: CLIProxyAPI build dependency checksum mismatch: $archive" >&2
    return 1
  fi
}

build_cliproxyapi() {
  local architecture="${1:-$(uname -m)}" go_arch go_host go_sha256
  case "$architecture" in
    arm64) go_arch=arm64 ;;
    x86_64) go_arch=amd64 ;;
    *) echo "error: unsupported helper architecture: $architecture" >&2; return 1 ;;
  esac
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) go_host=arm64; go_sha256="$CLIPROXYAPI_GO_SHA256" ;;
    Darwin-x86_64) go_host=amd64; go_sha256="$CLIPROXYAPI_GO_AMD64_SHA256" ;;
    *) echo "error: building the subscription helper requires macOS" >&2; return 1 ;;
  esac
  local cache="$PWD/.build/cliproxyapi"
  local recipe
  recipe="$(cat scripts/lib/cliproxyapi.sh scripts/cliproxyapi/local-only.patch | shasum -a 256 | awk '{print $1}')"
  local built="$cache/$CLIPROXYAPI_VERSION/$recipe/$architecture"
  CLIPROXYAPI_BUILT_DIRECTORY="$built"
  if [[ -f "$built/binary.sha256" && -x "$built/cliproxyapi" && -f "$built/LICENSE" ]] \
      && (cd "$built" && shasum -a 256 -c binary.sha256 >/dev/null 2>&1); then
    return
  fi

  mkdir -p "$cache" "$built"
  local archive="$cache/source-$CLIPROXYAPI_VERSION.tar.gz"
  cliproxyapi_download \
    "https://codeload.github.com/router-for-me/CLIProxyAPI/tar.gz/refs/tags/v$CLIPROXYAPI_VERSION" \
    "$archive" "$CLIPROXYAPI_SOURCE_SHA256"
  local toolchain="$cache/go-$CLIPROXYAPI_GO_VERSION-$go_host"
  local go_archive="$cache/go$CLIPROXYAPI_GO_VERSION.darwin-$go_host.tar.gz"
  cliproxyapi_download "https://go.dev/dl/go$CLIPROXYAPI_GO_VERSION.darwin-$go_host.tar.gz" \
    "$go_archive" "$go_sha256"
  if [[ ! -x "$toolchain/go/bin/go" ]]; then
    mkdir -p "$toolchain"
    tar -xzf "$go_archive" -C "$toolchain"
  fi

  local source="$built/source"
  rm -rf "$source"
  mkdir -p "$source"
  tar -xzf "$archive" --strip-components=1 -C "$source"
  patch --batch --fuzz=0 -d "$source" -p1 < scripts/cliproxyapi/local-only.patch
  echo "▶ building CLIProxyAPI $CLIPROXYAPI_VERSION ($architecture) with the local-only patch"
  (
    cd "$source" || exit
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_host" GOTOOLCHAIN=local GOENV=off GOFLAGS='' GOWORK=off \
      GOPATH="$cache/go-path" GOCACHE="$cache/go-cache" \
      "$toolchain/go/bin/go" test -mod=readonly ./sdk/cliproxy/auth \
      -run '^TestJarvisHTTP2ProtocolErrorCooldown$' -count=1 -v
    CGO_ENABLED=0 GOOS=darwin GOARCH="$go_arch" GOTOOLCHAIN=local GOENV=off GOFLAGS='' GOWORK=off \
      GOPATH="$cache/go-path" GOCACHE="$cache/go-cache" \
      "$toolchain/go/bin/go" build -mod=readonly -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.Version=$CLIPROXYAPI_VERSION-jarvis-local" \
      -o "$built/cliproxyapi.partial" ./cmd/server
  )
  mv "$built/cliproxyapi.partial" "$built/cliproxyapi"
  cp "$source/LICENSE" "$built/LICENSE"
  (cd "$built" && shasum -a 256 cliproxyapi > binary.sha256)
}

bundle_cliproxyapi() {
  local app="$1" architecture architectures
  local binaries=()
  architectures="$(lipo -archs "$app/Contents/MacOS/JarvisApp")"
  for architecture in $architectures; do
    build_cliproxyapi "$architecture"
    binaries+=("$CLIPROXYAPI_BUILT_DIRECTORY/cliproxyapi")
  done
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/cliproxyapi"
  chmod 755 "$app/Contents/MacOS/cliproxyapi"
  mkdir -p "$app/Contents/Resources/Licenses"
  install -m 644 "$CLIPROXYAPI_BUILT_DIRECTORY/LICENSE" \
    "$app/Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt"
}
