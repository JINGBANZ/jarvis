#!/usr/bin/env bash
# The native helper links system SQLite; no runtime downloads or package installation.
bundle_reference_helper() {
  local app="$1" configuration="$2"
  local destination="$app/Contents/Resources/ReferenceHelper"
  local binary
  binary="$(swift build -c "$configuration" --show-bin-path)/JarvisReferenceHelper"
  [[ -x "$binary" ]] || return 1
  rm -rf "$destination"
  mkdir -p "$destination"
  cp "$binary" "$destination/JarvisReferenceHelper"
  if [[ "$configuration" == release ]]; then
    /usr/bin/strip -S -x "$destination/JarvisReferenceHelper"
  fi
}

sign_reference_helper() {
  local app="$1" identity="$2"
  shift 2
  codesign --force "$@" --sign "$identity" "$app/Contents/Resources/ReferenceHelper/JarvisReferenceHelper"
}
