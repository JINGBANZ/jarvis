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
#                   Sources/JarvisOverlay are the deliberately thin OS-bound shell outside Core).
#                   Overlay *appearance* is a preference store, so it lives in Config/ with the
#                   others and is control plane, not delivery.
#   Audio/          capture-side buffering and speech-activity policy ahead of admission
#   Support/        Clock, retry schedule, and task plumbing the kernel depends on
#   Config/ is NOT kernel: it is the control plane the kernel is handed a frozen snapshot of.
#   Brain/          the BrainClient port and route/model types. Core describes brains and never
#                   runs one: every concrete adapter — the OpenAI URLSession transport and the
#                   local-agent CLI subtree with its Process plumbing — lives in
#                   Sources/JarvisBrainProviders.
#   Prompts/        predefined model-facing text for the kernel's own prompts. Provider-specific
#                   prompt text moved out with its adapter, still under the JarvisPrompts name.
#   Screen/         the ScreenCapturing port, snapshot model, and pure window-selection and
#                   recognized-text-layout logic. Foundation-only: the screencapture helper
#                   process, transient JPEG, and cleanup-verification latch live at the macOS edge
#                   in Sources/JarvisScreenCapture, behind the port.
#   PrepMaterial/   the PrepMaterialSearching port, chunk model, and pure BM25 index — same shape as
#                   Screen/: file reading and per-format extraction (PDFKit, textutil) live at the
#                   macOS edge in Sources/JarvisApp/PrepMaterial, behind the port.
#   Diagnostics/CaptureReadinessMonitor.swift, AudioContinuityWitness*.swift,
#   AudioContinuityMatcher.swift
#                   the capture-heartbeat source and capture health policy, which the diagram
#                   places inside the kernel even though they live beside persistence code
#
# Deliberately outside the covered paths today; each joins with the slice that clears it:
#   Diagnostics/ (rest)
#                   evidence persistence by definition; only the heartbeat/health files above are
#                   kernel.
#
# Separately covered (admission_paths below):
#   Diagnostics/Log.swift
#                   `jlog` itself. It is not kernel code, but the kernel calls it from inside the
#                   live attempt path, so what it does on the caller is a kernel concern. Since the
#                   diagnostics move onto the shared evidence transport it must only build a typed
#                   event and admit it — no Console call, no file access. It is exempt from the
#                   persistence-reach-through check below precisely because naming the shared
#                   transport is its job.
#
# Rules a later slice adds — do not read today's set as the finished contract:
#   - Nothing outstanding for the kernel itself. `Sources/JarvisApp` still records some Activity
#     notices directly; that is composition, not kernel, and it moves with the Activity persistence
#     slice.

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
    Sources/JarvisCore/PrepMaterial
    Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift
    Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift
    "Sources/JarvisCore/Diagnostics/AudioContinuityWitness+Types.swift"
    Sources/JarvisCore/Diagnostics/AudioContinuityMatcher.swift
)

# Paths checked for direct OS reach-through only. See the note above.
admission_paths=(
    Sources/JarvisCore/Diagnostics/Log.swift
)

# Direct OS reach-through. File, process, network, and Console access belong behind injected ports
# and the evidence stack, never inline in coaching policy.
os_pattern='\bFileManager\b|\bFileHandle\b|\bProcess\b|\bURLSession\b|\bNSLog\b'

# Evaluator and sealed-session types, plus the concrete evidence-persistence machinery. The kernel
# may emit through its narrow observer ports (BrainTrafficAuditing, CoachingAttemptAuditing); it may
# never name the offline analysis surface or the persistence implementation behind those ports.
# Persistence singletons are included: the kernel may name a port and the closed `ActivityEvent`
# vocabulary, but never the concrete `ActivityLog` behind it, and never a process-wide `.shared`
# instance of anything — a singleton makes two live drivers share whichever one happens to be
# enabled, which is exactly the coupling injected ports exist to remove.
sealed_pattern='\bAgenticEvaluation\b|\bAgenticEvaluator\b|\bEvaluationTranscript\b|\bEvalReportPage\b|\bSessionEvidenceIndex\b|\bSessionMetrics\b|\bSessionStore\b|\bFileSessionAudit\b|\bSessionAuditWorker\b|\bSessionAuditFileWriter\b|\bActivityLog\b|\.shared\b'

check() {
    local label="$1"
    local pattern="$2"
    shift 2
    local paths=("$@")

    local scan_status=0
    local matches
    matches="$(/usr/bin/grep -RInE "$pattern" "${paths[@]}")" \
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

# Control-plane storage. Preferences, secrets, and provider discovery are read at Start or at an
# explicit between-attempt boundary and frozen into an immutable `SessionPlan` revision; a coaching
# turn is handed the frozen value. Reading a preference inside an attempt would let a coaching
# outcome depend on disk latency and on whichever value happened to be current partway through the
# turn — exactly the dependency the Lean Coaching Path Rule exists to remove.
storage_pattern='\bUserDefaults\b|\bBrainPreferences\b|\bScreenCapturePreferences\b|\bTranscriptionPreferences\b|\bOverlayAppearance\b|\bSecretStore\b'

check "OS reach-through" "$os_pattern" "${kernel_paths[@]}"
check "evaluator/sealed-session reach-through" "$sealed_pattern" "${kernel_paths[@]}"
check "control-plane storage reach-through" "$storage_pattern" "${kernel_paths[@]}"
check "diagnostic-admission OS reach-through" "$os_pattern" "${admission_paths[@]}"

echo "Coaching-kernel dependency guard passed."
