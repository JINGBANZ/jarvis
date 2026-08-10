#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

capture_source="Sources/JarvisApp/Capture/AggregateEchoCapture.swift"
benchmark_capture_source="Sources/JarvisApp/Benchmark/SystemAudioBenchmarkCapture.swift"
benchmark_standard_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Standard.swift"
benchmark_reconnect_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Reconnect.swift"
benchmark_script="scripts/transcription-benchmark.sh"
if [ ! -f "$capture_source" ]; then
    echo "Audio capture guard: $capture_source not found; refusing to pass." >&2
    exit 1
fi
if [ ! -f "$benchmark_capture_source" ]; then
    echo "Audio capture guard: $benchmark_capture_source not found; refusing to pass." >&2
    exit 1
fi
if [ ! -f "$benchmark_standard_source" ] || [ ! -f "$benchmark_reconnect_source" ] \
    || [ ! -f "$benchmark_script" ]; then
    echo "Audio capture guard: transcription benchmark sources not found; refusing to pass." >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker)' \
    "$benchmark_standard_source" \
    || ! /usr/bin/grep -Fq 'TranscriptionBenchmarkAbortMonitor.run' \
    "$benchmark_standard_source" \
    || ! /usr/bin/grep -Fq 'trap abort_run INT TERM' "$benchmark_script"; then
    echo "Every transcription benchmark mode must stop capture when its command is interrupted." >&2
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
if /usr/bin/grep -Eq \
    'confirm-network-interruption|request-(disable|restore)-network|ack-(disable|restore)-network' \
    "$benchmark_reconnect_source" "$benchmark_script"; then
    echo "Reconnect benchmark must not coordinate host network interruption." >&2
    exit 1
fi
if /usr/bin/grep -Eq \
    '(^|[[:space:]/])(networksetup|ifconfig|pfctl|route|ipconfig|airport)([[:space:]]|$)' \
    "$benchmark_reconnect_source" "$benchmark_script"; then
    echo "Reconnect benchmark must not change host network state." >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'beginBenchmarkTransportInterruption' "$benchmark_reconnect_source" \
    || ! /usr/bin/grep -Fq 'endBenchmarkTransportInterruption' "$benchmark_reconnect_source"; then
    echo "Reconnect benchmark must scope interruption to Jarvis's transcription transport." >&2
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
