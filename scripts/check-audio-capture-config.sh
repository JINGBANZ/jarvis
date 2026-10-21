#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/guard.sh

capture_source="Sources/JarvisApp/Capture/AggregateEchoCapture.swift"
benchmark_capture_source="Sources/JarvisApp/Benchmark/SystemAudioBenchmarkCapture.swift"
benchmark_standard_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Standard.swift"
benchmark_reconnect_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Reconnect.swift"
benchmark_turns_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner+Turns.swift"
benchmark_runner_source="Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner.swift"
benchmark_fixtures_source="Sources/JarvisApp/Benchmark/SyntheticSpeechFixtures.swift"
benchmark_script="scripts/transcription-benchmark.sh"
normal_session_contract="Sources/JarvisCore/Transcription/TranscriptionSession.swift"
normal_app_wiring=(
    "Sources/JarvisApp/App/AppDelegate.swift"
    "Sources/JarvisApp/App/SessionComposition.swift"
)
session_factory="Sources/JarvisApp/Capture/TranscriptionSessionFactory.swift"
for path in "$capture_source" "$benchmark_capture_source" "$benchmark_standard_source" \
    "$benchmark_reconnect_source" "$benchmark_turns_source" "$benchmark_runner_source" \
    "$benchmark_fixtures_source" "$benchmark_script" "$normal_session_contract" \
    "$session_factory" "${normal_app_wiring[@]}" Package.swift Resources/Info.plist; do
    if [[ ! -f "$path" || ! -r "$path" ]]; then
        echo "Audio capture guard: $path missing or unreadable; refusing to pass." >&2
        exit 1
    fi
done
if ! /usr/bin/grep -Fq 'TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker)' \
    "$benchmark_standard_source" \
    || ! /usr/bin/grep -Fq 'TranscriptionBenchmarkEventRecorder(abortMarker: abortMarker)' \
    "$benchmark_turns_source" \
    || ! /usr/bin/grep -Fq 'TranscriptionBenchmarkAbortMonitor.run' \
    "$benchmark_runner_source" \
    || ! /usr/bin/grep -Fq 'trap abort_run HUP INT TERM' "$benchmark_script"; then
    echo "Every transcription benchmark mode must stop capture when its command is interrupted." >&2
    exit 1
fi
if ! /usr/bin/grep -Eq 'muteBehavior[[:space:]]*=[[:space:]]*CATapMuteBehavior\.muted[[:space:]]*$' "$benchmark_capture_source"; then
    echo "Transcription benchmark playback must be captured with hardware output muted." >&2
    exit 1
fi
guard_forbid "Aggregate capture must start immediately; tap auto-start stalls the microphone." \
    -nE '^[[:space:]]*kAudioAggregateDeviceTapAutoStartKey[[:space:]]*:' "$capture_source"
guard_forbid "Reconnect benchmark must not coordinate host network interruption." \
    -nE 'confirm-network-interruption|request-(disable|restore)-network|ack-(disable|restore)-network' \
    "$benchmark_reconnect_source" "$benchmark_script"
guard_forbid "Reconnect benchmark must not change host network state." \
    -nE '(^|[[:space:]/])(networksetup|ifconfig|pfctl|route|ipconfig|airport)([[:space:]]|$)' \
    "$benchmark_reconnect_source" "$benchmark_script"
if ! /usr/bin/grep -Fq 'transportControl.beginInterruption()' "$benchmark_reconnect_source" \
    || ! /usr/bin/grep -Fq 'transportControl.endInterruption()' "$benchmark_reconnect_source"; then
    echo "Reconnect benchmark must scope interruption to Jarvis's transcription transport." >&2
    exit 1
fi
guard_forbid "Normal transcription contracts and app wiring must not expose benchmark capabilities." \
    -nF 'TranscriptionBenchmark' "$normal_session_contract" "${normal_app_wiring[@]}"
# main.swift alone may select the live e2e mode.
live_e2e_references="$(guard_scan -RIl 'LiveE2E' Sources/JarvisApp/App \
    Sources/JarvisCore/Transcription Sources/JarvisCore/Coach)"
while IFS= read -r reference; do
    if [ -z "$reference" ] || [ "$reference" = "Sources/JarvisApp/App/main.swift" ]; then
        continue
    fi
    echo "The live e2e mode must stay out of normal app wiring and the coaching kernel: $reference" >&2
    exit 1
done <<< "$live_e2e_references"
fixture_references="$(guard_scan -RIlE 'FixtureAudioSource|FixtureScreenCapture' Sources)"
while IFS= read -r reference; do
    case "$reference" in
        ""|Sources/JarvisApp/LiveE2E/*) ;;
        *)
            echo "Fixture audio and screen sources belong to the live e2e mode only: $reference" >&2
            exit 1
            ;;
    esac
done <<< "$fixture_references"
if ! /usr/bin/grep -Fq '.define("JARVIS_LIVE_E2E", .when(configuration: .debug))' Package.swift \
    || ! /usr/bin/grep -Fq 'swiftSettings: liveE2ESettings' Package.swift \
    || ! /usr/bin/grep -Fq 'liveE2ESettings + ' Package.swift; then
    echo "Package.swift must define JARVIS_LIVE_E2E for debug builds of JarvisCore and JarvisApp only." >&2
    exit 1
fi
for live_e2e_source in Sources/JarvisApp/LiveE2E/*.swift Sources/JarvisCore/LiveE2E/*.swift; do
    if ! /usr/bin/head -n 1 "$live_e2e_source" | /usr/bin/grep -Eq '^#if JARVIS_LIVE_E2E( |$)'; then
        echo "Live e2e sources must compile only into debug builds: $live_e2e_source must start with #if JARVIS_LIVE_E2E" >&2
        exit 1
    fi
done
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
