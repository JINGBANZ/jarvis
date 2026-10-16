# The same source and privacy patch supply development and release bundles.
CLIPROXYAPI_VERSION="8.0.20"
CLIPROXYAPI_SOURCE_SHA256="3c0dacdf6195a5f7f6cd9c2a7d388c168ed4d0fa14fafac62f6228710e339cf9"
CLIPROXYAPI_GO_VERSION="1.26.9"
CLIPROXYAPI_GO_SHA256="f9bb7c0a02506c5d9bf0d1eb1f7ee6c7684f844ae49558308a0427b830e022cc"

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
  if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
    echo "error: the bundled subscription helper requires an Apple silicon Mac" >&2
    return 1
  fi
  local cache="$PWD/.build/cliproxyapi"
  local recipe
  recipe="$(cat scripts/lib/cliproxyapi.sh scripts/cliproxyapi/local-only.patch | shasum -a 256 | awk '{print $1}')"
  local built="$cache/$CLIPROXYAPI_VERSION/$recipe"
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
  local toolchain="$cache/go-$CLIPROXYAPI_GO_VERSION"
  local go_archive="$cache/go$CLIPROXYAPI_GO_VERSION.darwin-arm64.tar.gz"
  cliproxyapi_download "https://go.dev/dl/go$CLIPROXYAPI_GO_VERSION.darwin-arm64.tar.gz" \
    "$go_archive" "$CLIPROXYAPI_GO_SHA256"
  if [[ ! -x "$toolchain/go/bin/go" ]]; then
    mkdir -p "$toolchain"
    tar -xzf "$go_archive" -C "$toolchain"
  fi

  local source="$built/source"
  rm -rf "$source"
  mkdir -p "$source"
  tar -xzf "$archive" --strip-components=1 -C "$source"
  patch --batch --fuzz=0 -d "$source" -p1 < scripts/cliproxyapi/local-only.patch
  echo "▶ building CLIProxyAPI $CLIPROXYAPI_VERSION with the local-only privacy patch"
  (
    cd "$source"
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOTOOLCHAIN=local GOENV=off GOFLAGS= GOWORK=off \
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
  local app="$1"
  build_cliproxyapi
  install -m 755 "$CLIPROXYAPI_BUILT_DIRECTORY/cliproxyapi" "$app/Contents/MacOS/cliproxyapi"
  mkdir -p "$app/Contents/Resources/Licenses"
  install -m 644 "$CLIPROXYAPI_BUILT_DIRECTORY/LICENSE" \
    "$app/Contents/Resources/Licenses/CLIProxyAPI-LICENSE.txt"
}
