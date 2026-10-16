#!/usr/bin/env bash
# Build-time downloads only. The assembled application never installs dependencies.
REFERENCE_PYTHON_VERSION=3.13.16
REFERENCE_PYTHON_RELEASE=20261013
# Source commit 9e40cba825ca0997a01cab9f60a0b15ffb976af2; its downloads.json pins zlib-ng 2.2.4.
REFERENCE_NAMESPACE_LICENSE_SHA256=03c4e02af8cbe96dd3a9bfaac9ee27ec6a8e9a3ee38ed7b290d50495c11eea48
REFERENCE_ZLIB_NG_SHA256=00bbd88709bc416cb96160ab61d3e1c8f76e106799af7328d0fe434dc7dd5004
REFERENCE_PYTHON_FULL_SHA256=3497822d8bf4884bc79258f62668f985654d03d40ec74da4ca9ae7a5667c4362
REFERENCE_PYTHON_SHA256=16a5332fb0dcb77f163fc8f8cbccd95be1644cc53e68e5d2a79f50afd6680a0e

prepare_reference_helper() {
  local cache="$PWD/.build/reference-helper"
  local archive="$cache/python.tar.gz"
  local stamp
  stamp="$(cat scripts/reference-helper/requirements.lock scripts/lib/reference-helper.sh scripts/reference-helper/verify_bundle.py scripts/reference-helper/wheels.sha256 | shasum -a 256 | cut -d ' ' -f 1)"
  mkdir -p "$cache"
  if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" != "$REFERENCE_PYTHON_SHA256" ]]; then
    curl --fail --location --retry 3 \
      "https://github.com/astral-sh/python-build-standalone/releases/download/$REFERENCE_PYTHON_RELEASE/cpython-$REFERENCE_PYTHON_VERSION%2B$REFERENCE_PYTHON_RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz" \
      --output "$archive"
  fi
  [[ "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" == "$REFERENCE_PYTHON_SHA256" ]] || return 1
  if [[ ! -f "$cache/ready" ]] || [[ "$(cat "$cache/ready")" != "$stamp" ]] \
      || ! (cd "$cache" && shasum -a 256 --check manifest.sha256 >/dev/null 2>&1); then
    local full="$cache/python-full.tar.zst"
    if [[ ! -f "$full" ]] || [[ "$(shasum -a 256 "$full" | cut -d ' ' -f 1)" != "$REFERENCE_PYTHON_FULL_SHA256" ]]; then
      curl --fail --location --retry 3 \
        "https://github.com/astral-sh/python-build-standalone/releases/download/$REFERENCE_PYTHON_RELEASE/cpython-$REFERENCE_PYTHON_VERSION%2B$REFERENCE_PYTHON_RELEASE-aarch64-apple-darwin-pgo%2Blto-full.tar.zst" \
        --output "$full"
    fi
    [[ "$(shasum -a 256 "$full" | cut -d ' ' -f 1)" == "$REFERENCE_PYTHON_FULL_SHA256" ]] || return 1
    mkdir -p "$cache/notices"
    tar xf "$full" -C "$cache/notices" python/PYTHON.json python/licenses
    # This PBS archive references zlib-ng's notice but omits it. Preserve the exact source notice.
    local zlib="$cache/zlib-ng.tar.gz"
    if [[ ! -f "$zlib" ]] || [[ "$(shasum -a 256 "$zlib" | cut -d ' ' -f 1)" != "$REFERENCE_ZLIB_NG_SHA256" ]]; then
      curl --fail --location --retry 3 \
        https://github.com/python/cpython-source-deps/archive/refs/tags/zlib-ng-2.2.4.tar.gz --output "$zlib"
    fi
    [[ "$(shasum -a 256 "$zlib" | cut -d ' ' -f 1)" == "$REFERENCE_ZLIB_NG_SHA256" ]] || return 1
    tar xOf "$zlib" cpython-source-deps-zlib-ng-2.2.4/LICENSE.md > "$cache/notices/python/licenses/LICENSE.zlib-ng.txt"
    rm -rf "$cache/python"
    tar xzf "$archive" -C "$cache"
    mkdir -p .build/reference-wheels
    if ! (cd .build/reference-wheels && shasum -a 256 --check ../../scripts/reference-helper/wheels.sha256 >/dev/null 2>&1); then
      "$cache/python/bin/python3" -I -m pip download --disable-pip-version-check --only-binary=:all: \
        --require-hashes -r scripts/reference-helper/requirements.lock --dest .build/reference-wheels
    fi
    (cd .build/reference-wheels && shasum -a 256 --check ../../scripts/reference-helper/wheels.sha256 >/dev/null)
    "$cache/python/bin/python3" -I -m pip install --disable-pip-version-check --no-compile --no-index \
      --find-links .build/reference-wheels --require-hashes -r scripts/reference-helper/requirements.lock
    # Both Namespace wheels omit the source project's license; the release tree has no NOTICE.
    local namespace_license="$cache/namespace-LICENSE"
    if [[ ! -f "$namespace_license" ]] || [[ "$(shasum -a 256 "$namespace_license" | cut -d ' ' -f 1)" != "$REFERENCE_NAMESPACE_LICENSE_SHA256" ]]; then
      curl --fail --location --retry 3 \
        https://raw.githubusercontent.com/lance-format/lance-namespace/8528f9f250336e608d6d592287af6ad67a0ef30e/LICENSE \
        --output "$namespace_license"
    fi
    [[ "$(shasum -a 256 "$namespace_license" | cut -d ' ' -f 1)" == "$REFERENCE_NAMESPACE_LICENSE_SHA256" ]] || return 1
    local distribution
    for distribution in lance_namespace lance_namespace_urllib3_client; do
      mkdir -p "$cache/python/lib/python3.13/site-packages/$distribution-0.13.0.dist-info/licenses"
      cp "$namespace_license" "$cache/python/lib/python3.13/site-packages/$distribution-0.13.0.dist-info/licenses/LICENSE"
    done
    "$cache/python/bin/python3" -I -B scripts/reference-helper/verify_bundle.py "$cache"
    printf '%s' "$stamp" > "$cache/ready"
  fi
}

bundle_reference_helper() {
  prepare_reference_helper
  local destination="$1/Contents/Resources/ReferenceHelper"
  mkdir -p "$destination"
  ditto .build/reference-helper/python "$destination/python"
  ditto .build/reference-helper/notices "$destination/Notices"
  cp scripts/reference-helper/helper.py scripts/reference-helper/requirements.lock "$destination/"
  # Runtime and wheel license files remain inside their original distributions.
}

sign_reference_helper() {
  local app="$1" identity="$2"
  shift 2
  local code
  while IFS= read -r -d '' code; do
    if file -b "$code" | grep -q 'Mach-O'; then
      codesign --force "$@" --sign "$identity" "$code"
    fi
  done < <(find "$app/Contents/Resources/ReferenceHelper" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0)
}
