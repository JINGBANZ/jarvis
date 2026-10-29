#!/usr/bin/env bash
# The native helper links system SQLite; no runtime downloads or package installation.
bundle_reference_helper() {
  local app="$1" configuration="$2" artifacts="$3"
  local destination="$app/Contents/Resources/ReferenceHelper"
  local binary privacy
  binary="$artifacts/JarvisReferenceHelper"
  privacy="$artifacts/ZIPFoundation_ZIPFoundation.bundle"
  # The Swift Build backend (Swift 6.4+) emits a macOS-layout bundle; the legacy backend a flat one.
  [[ -x "$binary" && ( -f "$privacy/PrivacyInfo.xcprivacy" \
      || -f "$privacy/Contents/Resources/PrivacyInfo.xcprivacy" ) ]] || return 1
  rm -rf "$destination"
  mkdir -p "$destination"
  cp "$binary" "$destination/JarvisReferenceHelper"
  rm -rf "$app/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"
  cp -R "$privacy" "$app/Contents/Resources/ZIPFoundation_ZIPFoundation.bundle"
  if [[ "$configuration" == release ]]; then
    /usr/bin/strip -S -x "$destination/JarvisReferenceHelper"
  fi
}

sign_reference_helper() {
  local app="$1" identity="$2"
  shift 2
  codesign --force "$@" --sign "$identity" "$app/Contents/Resources/ReferenceHelper/JarvisReferenceHelper"
}
