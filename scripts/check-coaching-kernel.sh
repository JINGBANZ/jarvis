#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Dependency guard over the product-critical coaching kernel: finalized transcript admission
# through overlay delivery (wiki/lean-coaching-core.md, "Product-critical coaching kernel" in the
# destination diagram; decision record "2026-08-16 — Session evidence uses one shared stack and two
# projections"). From admission to delivery, coaching depends only on deterministic in-memory policy
# and explicitly injected critical ports — so the kernel may not reach for the OS or for
# evaluator/sealed-session machinery directly. Keeping this in the Gate makes a new reach-through
# fail the normal test run instead of waiting on a future manual audit to notice it.
#
# Covered paths — the kernel per the destination diagram:
#   Coach/          attempt scheduler, forward-only route state, attempt runner, history commit
#   Transcription/  finalized transcript admission and the transcription ports
#   Triggers/       trigger and turn-substance policy feeding the scheduler
#   Overlay/        the enabled overlay output port (delivery itself; the AppKit panels in
#                   Sources/JarvisOverlay are the deliberately thin OS-bound shell outside Core)
#   Audio/          capture-side buffering and speech-activity policy ahead of admission
#   Support/        Clock, retry schedule, and task plumbing the kernel depends on
#   Brain/          the BrainClient port and route/model types — minus Adapters/ (below)
#   Screen/         the ScreenCapturing port, snapshot model, and pure window-selection and
#                   recognized-text-layout logic. Foundation-only: the screencapture helper
#                   process, transient JPEG, and cleanup-verification latch live at the macOS edge
#                   in Sources/JarvisScreenCapture, behind the port.
#   Diagnostics/CaptureReadinessMonitor.swift, AudioContinuityWitness*.swift,
#   AudioContinuityMatcher.swift
#                   the capture-heartbeat source and capture health policy, which the diagram
#                   places inside the kernel even though they live beside persistence code
#
# Deliberately outside the covered paths today; each joins with the slice that clears it:
#   Brain/Adapters/ concrete provider adapters (URLSession, CLI Process). They are outside the
#                   kernel by design and move outward with the Phase 4 adapter move; until then
#                   they legitimately hold the OS symbols this guard bans.
#   Diagnostics/ (rest)
#                   evidence persistence by definition; only the heartbeat/health files above are
#                   kernel.
#
# Rules a later slice adds — do not read today's set as the finished contract:
#   - Persistence singletons (ActivityLog / .shared / jlog) arrive with the Activity projection and
#     the diagnostics move onto SessionEvidence. CoachDriver and TranscriptionCoachingCoordinator
#     still take an injected ActivityLog defaulting to .shared and call jlog synchronously, so that
#     rule cannot land green yet.

kernel_paths=(
    Sources/JarvisCore/Coach
    Sources/JarvisCore/Transcription
    Sources/JarvisCore/Triggers
    Sources/JarvisCore/Overlay
    Sources/JarvisCore/Audio
    Sources/JarvisCore/Support
    Sources/JarvisCore/Brain
    Sources/JarvisCore/Screen
    Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift
    Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift
    "Sources/JarvisCore/Diagnostics/AudioContinuityWitness+Types.swift"
    Sources/JarvisCore/Diagnostics/AudioContinuityMatcher.swift
)

# Direct OS reach-through. File, process, network, and Console access belong behind injected ports
# and the evidence stack, never inline in coaching policy.
os_pattern='\bFileManager\b|\bFileHandle\b|\bProcess\b|\bURLSession\b|\bNSLog\b'

# Evaluator and sealed-session types, plus the concrete evidence-persistence machinery. The kernel
# may emit through its narrow observer ports (BrainTrafficAuditing, CoachingAttemptAuditing); it may
# never name the offline analysis surface or the persistence implementation behind those ports.
sealed_pattern='\bAgenticEvaluation\b|\bAgenticEvaluator\b|\bEvaluationTranscript\b|\bEvalReportPage\b|\bSessionEvidenceIndex\b|\bSessionMetrics\b|\bSessionStore\b|\bFileSessionAudit\b|\bSessionAuditWorker\b|\bSessionAuditFileWriter\b'

check() {
    local label="$1"
    local pattern="$2"

    local scan_status=0
    local matches
    matches="$(/usr/bin/grep -RInE --exclude-dir=Adapters "$pattern" "${kernel_paths[@]}")" \
        || scan_status=$?
    if [ "$scan_status" -gt 1 ]; then
        echo "Coaching-kernel $label scan failed; refusing to pass without a complete scan." >&2
        exit "$scan_status"
    fi

    # A line whose first non-whitespace is `//` is prose about a symbol, not API use, so it does
    # not weaken the rule. Trailing comments on code lines still count, which errs strict.
    local filter_status=0
    local violations
    violations="$(printf '%s' "$matches" | /usr/bin/grep -vE '^[^:]+:[0-9]+:[[:space:]]*//')" \
        || filter_status=$?
    if [ "$filter_status" -gt 1 ]; then
        echo "Coaching-kernel $label comment filtering failed; refusing to pass." >&2
        exit "$filter_status"
    fi
    if [ -n "$violations" ]; then
        echo "Coaching-kernel $label violation — inject a port instead of reaching through:" >&2
        echo "$violations" >&2
        exit 1
    fi
}

check "OS reach-through" "$os_pattern"
check "evaluator/sealed-session reach-through" "$sealed_pattern"

echo "Coaching-kernel dependency guard passed."
