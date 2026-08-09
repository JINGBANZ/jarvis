#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

capture_source="Sources/JarvisApp/Capture/AggregateEchoCapture.swift"
benchmark_capture_source="Sources/JarvisApp/Benchmark/SystemAudioBenchmarkCapture.swift"
if [ ! -f "$capture_source" ]; then
    echo "Audio capture guard: $capture_source not found; refusing to pass." >&2
    exit 1
fi
if [ ! -f "$benchmark_capture_source" ]; then
    echo "Audio capture guard: $benchmark_capture_source not found; refusing to pass." >&2
    exit 1
fi
if ! /usr/bin/grep -Eq 'muteBehavior[[:space:]]*=[[:space:]]*CATapMuteBehavior\.muted[[:space:]]*$' "$benchmark_capture_source"; then
    echo "Transcription benchmark playback must be captured with hardware output muted." >&2
    exit 1
fi
if /usr/bin/grep -Eq '^[[:space:]]*kAudioAggregateDeviceTapAutoStartKey[[:space:]]*:' "$capture_source"; then
    echo "Aggregate capture must start immediately; tap auto-start waits for system-audio writers and stalls the microphone." >&2
    exit 1
fi

usage_description=""
if ! usage_description="$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' Resources/Info.plist 2>/dev/null)"; then
    echo "Resources/Info.plist must describe system-audio capture for Core Audio process taps." >&2
    exit 1
fi
if [ -z "$usage_description" ]; then
    echo "Resources/Info.plist must describe system-audio capture for Core Audio process taps." >&2
    exit 1
fi

echo "Audio capture configuration guard passed."
