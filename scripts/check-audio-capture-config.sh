#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

capture_source="Sources/JarvisApp/Capture/AggregateEchoCapture.swift"
benchmark_capture_source="Sources/JarvisApp/Benchmark/SystemAudioBenchmarkCapture.swift"
benchmark_standard_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Standard.swift"
benchmark_reconnect_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Reconnect.swift"
benchmark_runner_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner.swift"
benchmark_fixtures_source="Sources/JarvisApp/Benchmark/SyntheticSpeechFixtures.swift"
benchmark_script="scripts/transcription-benchmark.sh"
normal_session_contract="Sources/JarvisCore/Transcription/TranscriptionSession.swift"
normal_app_wiring=(
    "Sources/JarvisApp/App/AppDelegate.swift"
    "Sources/JarvisApp/App/SessionComposition.swift"
)
session_factory="Sources/JarvisApp/Capture/TranscriptionSessionFactory.swift"
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
if ! /usr/bin/grep -Fq 'transportControl.beginInterruption()' "$benchmark_reconnect_source" \
    || ! /usr/bin/grep -Fq 'transportControl.endInterruption()' "$benchmark_reconnect_source"; then
    echo "Reconnect benchmark must scope interruption to Jarvis's transcription transport." >&2
    exit 1
fi
for wiring_source in "${normal_app_wiring[@]}"; do
    if [ ! -f "$wiring_source" ]; then
        echo "Audio capture guard: $wiring_source not found; refusing to pass." >&2
        exit 1
    fi
done
if /usr/bin/grep -Fq 'TranscriptionBenchmark' "$normal_session_contract" \
    || /usr/bin/grep -Fq 'TranscriptionBenchmark' "${normal_app_wiring[@]}"; then
    echo "Normal transcription contracts and app wiring must not expose benchmark capabilities." >&2
    exit 1
fi
# The live e2e mode is selected in main.swift alone: its symbols stay out of normal app wiring and
# the coaching kernel, and its fixture source never becomes a production audio source.
live_e2e_status=0
live_e2e_references="$(/usr/bin/grep -RIl 'LiveE2E' Sources/JarvisApp/App \
    Sources/JarvisCore/Transcription Sources/JarvisCore/Coach)" || live_e2e_status=$?
if [ "$live_e2e_status" -gt 1 ]; then
    echo "Audio capture guard: live e2e scan failed; refusing to pass." >&2
    exit 1
fi
while IFS= read -r reference; do
    if [ -z "$reference" ] || [ "$reference" = "Sources/JarvisApp/App/main.swift" ]; then
        continue
    fi
    echo "The live e2e mode must stay out of normal app wiring and the coaching kernel: $reference" >&2
    exit 1
done <<< "$live_e2e_references"
fixture_status=0
fixture_references="$(/usr/bin/grep -RIlE 'FixtureAudioSource|FixtureScreenCapture' Sources)" || fixture_status=$?
if [ "$fixture_status" -gt 1 ]; then
    echo "Audio capture guard: fixture source scan failed; refusing to pass." >&2
    exit 1
fi
while IFS= read -r reference; do
    case "$reference" in
        ""|Sources/JarvisApp/LiveE2E/*) ;;
        *)
            echo "Fixture audio and screen sources belong to the live e2e mode only: $reference" >&2
            exit 1
            ;;
    esac
done <<< "$fixture_references"
if ! /usr/bin/grep -Fq -- '--skip JarvisLiveTests' scripts/run-tests.sh; then
    echo "The Gate must never run the live e2e target; run-tests.sh has to skip JarvisLiveTests." >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'benchmark: TranscriptionBenchmarkInstrumentation? = nil' \
    "$session_factory"; then
    echo "Transcription benchmark instrumentation must remain absent by default." >&2
    exit 1
fi
if ! /usr/bin/grep -Fq 'func removeGeneratedAudio() throws' "$benchmark_fixtures_source" \
    || ! /usr/bin/grep -Fq 'try fixtures.removeGeneratedAudio()' "$benchmark_runner_source"; then
    echo "Benchmark fixture cleanup failures must prevent a successful run." >&2
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
