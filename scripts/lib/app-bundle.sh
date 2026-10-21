#!/usr/bin/env bash
source scripts/lib/cliproxyapi.sh
source scripts/lib/reference-helper.sh

assemble_app() {
  local app="$1" artifacts="$2" configuration="$3"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "$artifacts/JarvisApp" "$app/Contents/MacOS/JarvisApp"
  cp Resources/Info.plist "$app/Contents/Info.plist"
  cp Resources/Jarvis.icns "$app/Contents/Resources/Jarvis.icns"
  ditto "$artifacts/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
  # SwiftPM's Bundle.module locates these side-by-side resource bundles here.
  for resource in Jarvis_JarvisApp.bundle Jarvis_JarvisCore.bundle; do
    ditto "$artifacts/$resource" "$app/Contents/Resources/$resource"
  done
  # Both aliases must go: Sparkle's sandbox-only services would leave a dangling link.
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/Current/XPCServices" \
         "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
  bundle_cliproxyapi "$app"
  bundle_reference_helper "$app" "$configuration"
}
