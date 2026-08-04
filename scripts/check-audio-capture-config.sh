#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

capture_source="Sources/JarvisApp/Capture/AggregateEchoCapture.swift"
if /usr/bin/grep -Eq '^[[:space:]]*kAudioAggregateDeviceTapAutoStartKey[[:space:]]*:' "$capture_source"; then
    echo "Aggregate capture must start immediately; tap auto-start waits for system-audio writers and stalls the microphone." >&2
    exit 1
fi

usage_description="$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' Resources/Info.plist 2>/dev/null || true)"
if [ -z "$usage_description" ]; then
    echo "Resources/Info.plist must describe system-audio capture for Core Audio process taps." >&2
    exit 1
fi

echo "Audio capture configuration guard passed."
