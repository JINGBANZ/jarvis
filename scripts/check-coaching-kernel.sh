#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/guard.sh

# Gate: the coaching kernel may not reach the OS, evaluator/session types, or control-plane storage.
# Design: wiki/lean-coaching-core.md

kernel_paths=(
    Sources/JarvisCore/Coach
    Sources/JarvisCore/Transcription
    Sources/JarvisCore/Triggers
    Sources/JarvisCore/Overlay
    Sources/JarvisCore/Audio
    Sources/JarvisCore/Support
    Sources/JarvisCore/Brain
    Sources/JarvisCore/Prompts
    Sources/JarvisCore/Screen
    Sources/JarvisCore/References
    Sources/JarvisCore/Providers
    Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift
    Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift
    "Sources/JarvisCore/Diagnostics/AudioContinuityWitness+Types.swift"
    Sources/JarvisCore/Diagnostics/AudioContinuityMatcher.swift
)

# `jlog` is not kernel code but runs inside the attempt path, so it gets the OS check only. It is
# exempt from the sealed-session check because naming the shared evidence transport is its job.
admission_paths=(
    Sources/JarvisCore/Diagnostics/Log.swift
)

# `\bURLSession\w*`, not `\b...\b`, so prefixed types like `URLSessionWebSocketTask` match too.
os_pattern='\bFileManager\b|\bFileHandle\b|\bProcess\b|\bURLSession\w*|\bNSLog\b'

# The kernel emits through its observer ports only. `.shared` is banned because a singleton makes two
# live drivers share whichever instance happens to be enabled.
sealed_pattern='\bAgenticEvaluation\b|\bAgenticEvaluator\b|\bEvaluationTranscript\b|\bEvalReportPage\b|\bSessionEvidenceIndex\b|\bSessionMetrics\b|\bSessionStore\b|\bFileSessionAudit\b|\bSessionAuditWorker\b|\bSessionAuditFileWriter\b|\bActivityLog\b|\.shared\b'

check() {
    local label="$1"
    local pattern="$2"
    shift 2
    local paths=("$@")

    local matches violations
    matches="$(guard_scan -RInE "$pattern" "${paths[@]}")"
    # Whole-line comments are prose; trailing comments on code lines still count.
    violations="$(printf '%s' "$matches" | guard_scan -vE '^[^:]+:[0-9]+:[[:space:]]*//')"
    if [ -n "$violations" ]; then
        echo "Coaching-kernel $label violation — inject a port instead of reaching through:" >&2
        echo "$violations" >&2
        exit 1
    fi
}

# Preferences and secrets reach the kernel only as a frozen `SessionPlan` revision, so an attempt
# never depends on disk latency or a value that changed mid-turn.
storage_pattern='\bUserDefaults\b|\bBrainPreferences\b|\bScreenCapturePreferences\b|\bTranscriptionPreferences\b|\bOverlayAppearance\b|\bSecretStore\b'

check "OS reach-through" "$os_pattern" "${kernel_paths[@]}"
check "evaluator/sealed-session reach-through" "$sealed_pattern" "${kernel_paths[@]}"
check "control-plane storage reach-through" "$storage_pattern" "${kernel_paths[@]}"
check "diagnostic-admission OS reach-through" "$os_pattern" "${admission_paths[@]}"

echo "Coaching-kernel dependency guard passed."
