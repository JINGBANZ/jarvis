# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`CLAUDE.md`](./CLAUDE.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page. The load-bearing
> design decisions live in [`decisions.md`](./decisions.md).

## Current phase

**General technical-interview coaching, audio reliability, and local CLI brain providers are
implemented.** The coach covers behavioral, system-design, and coding questions. A direct request
whose specific answer depends on visible context missing from the conversation calls `capture_screen`
before `speak`; a fresh screenshot/OCR satisfies that request, while a fully stated question can be
answered without a reflexive capture. Realtime
transcription reconciles each `item_id` across VAD, delta, completion, and failure events; salvages
partial text while keeping unavailable items diagnostic-only; preserves every real system-audio
sample while padding only missing tap silence for VAD; and keeps AEC on a separate exact-length
reference. Content-free continuity checkpoints cover capture through server speech without
archiving PCM, and timestamp-interval correlation handles locally split or replayed utterances
without adding diagnostic text to the brain transcript.
Locally accepted WebSocket sends remain in a bounded memory-only recovery tail because Realtime does
not acknowledge audio appends; server audio-clock progress retires only a safe prefix, and a
replacement socket replays the rest after a half-open failure. A live Wi-Fi reconnect run confirms
that speech captured during the outage returns after recovery. The brain can also run through a
locally installed Claude Code or Codex CLI on the user's subscription; Settings → Brain auto-detects
both, reports Claude's current sign-in state from its bounded status command, and keeps the
OpenAI API-key path available. Codex also remains available to the explicit agentic session
evaluator. The ordered provider route uses one primary
plus a user-editable ordered fallback list, one target per coaching attempt, no failed-request replay
inside the attempt, automatic pending-work attempts with the newest finalized transcript, the
code-owned temporary/unknown failure threshold in
[`BrainRouteSession.failuresPerTarget`](../Sources/JarvisCore/Coach/BrainRouteSession.swift)—or one
proven permanent failure—before moving forward, and no automatic return to an earlier target.
Runtime movement never changes preferences; exhausting the finite route stops coaching with a fixed
typed Activity event. That route is implemented as immutable provider/model values, a pure
Foundation-only session cursor, a single-flight fresh-attempt scheduler, and the ordered Settings
Provider editor with one uninterrupted Primary/fallback route, a separate right-aligned Reasoning
effort row, and an explicit Transcription provider/key group. A first-open install remains
unconfigured until Primary is chosen. Local coaching uses persistent runtimes rather than launching
one process per model turn. Claude Code keeps
one initialized safe-mode query ready for the active target and leases it across an attempt's
complete tool loop while preparing its replacement. It disables built-in tools, settings sources,
session persistence, and MCP servers while preserving the user's OAuth session. Its runtime miss or
crash fails the provider attempt; there is no one-shot CLI fallback. Stop kills ready, leased, and
preparing process trees. Codex keeps one session-scoped app-server under a private `CODEX_HOME` and
prepares the first target-specific ephemeral thread at Session Start while transcription connects.
The first attempt leases it; later attempts open fresh threads, so coach and summarizer share one
runtime without crossing target configuration. Its read-only, never-approval, empty-MCP,
feature-disable envelope matches what `codex exec` coaching enforced, plus verified thread
ephemerality and a message/reasoning event allowlist that aborts a turn on any other item.
Saving an API key while running also preserves those live objects: existing Realtime sockets take
the key on their next reconnect, and an OpenAI brain update remains transactional. Audio
route rebuilds likewise retry before declaring capture unavailable, and stale capture callbacks
cannot stop a replacement session; repeated route notifications cannot reset one incident's bounded
budget. Activity persists stable event kinds and flushes at Stop. The sole evaluator is agentic: it
receives the complete session directory and reads the full, unfiltered `jarvis-activity.jsonl`
whenever it needs the user-visible sequence, alongside raw brain traffic, screenshots, and live
source code. Activity's one-click **Evaluate** action launches that evaluator and opens its saved
report; the standalone script calls the same Core implementation. The runtime ghost-mode rule
covers microphone transcription, audio-route loss, in-place CLI preflight, and Activity-audit
completion: no runtime error autonomously activates Jarvis, opens a browser, or presents a modal;
fixed notices remain available in Activity. The gate statically rejects unreviewed presentation APIs.

## Next action

Run the live prompt smoke on a fresh session: show an interview question without speaking its
details, ask “Jarvis, how can I solve this in one pass?”, and confirm the first action is
exactly one `capture_screen` followed by a screen-specific reply. Then ask a fully stated behavioral
question and confirm it can answer without an unnecessary capture. Finish the in-app Claude Code
provider smoke: confirm Settings shows it signed in, then confirm a coaching turn and screen request.
While that session runs, switch providers and confirm the next completed turn preserves context and
adds the provider-only success notice to Activity; then exercise a failed replacement and confirm
the pending conversation is preserved. Verify the first-open Brain state (no Primary selection,
disabled model/Add fallback, and Add API key), then configure multiple fallbacks and force a temporary
failure-budget transition, a proven-permanent one-attempt transition, an unavailable-target skip, and
final route exhaustion. Confirm no provider-specific tool state crosses attempts and verify a
successful fallback remains active without changing preferences. Configure Codex as Primary and
confirm `jarvis-debug.log` reports the target thread ready before the first coaching request and that
the turn completes on its app-server; then Stop and confirm neither the app-server nor its private
runtime home survives. Then Stop the Claude smoke and confirm no query child remains. The signed-in
Foundation-level Claude POC already verifies two turns on one native conversation; this remaining
smoke covers app wiring, TCC, audio, and overlay presentation. Exercise one
audio-route switch: Activity should say listening continues, the
next turn should include any unsent speech, and capture should recover
without rotating the session. Stop that session, click **Evaluate**, and confirm the agentic report
opens and identifies the temporary miss from the complete Activity log without misclassifying it as
a stopped conversation. The standard release checklist remains in
[build-and-run.md](./build-and-run.md).

## Built

Tested `JarvisCore` + `JarvisOverlay` harness is green (`./scripts/run-tests.sh`); `JarvisApp` is the
thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — transactional PCM + utterance buffering, adaptive content-free activity detection, non-destructive AEC reference alignment, and system-audio timeline preservation (`PCMBuffer`, `UtteranceBuffer`, `PCM16Framer`, `AudioDownmix`, `AdaptiveAudioActivityDetector`, `EchoReferenceAlignment`, `SystemAudioTimeline`).
- `Sources/JarvisCore/Transcription/` — realtime session wire contract, per-item event ledger, and rolling transcript (`RealtimeSession`, `RealtimeTranscriptionLedger`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Brain/` — provider-neutral `BrainClient`/attempt-scoped `BrainConversation` contracts and models stay at the root. `Adapters/OpenAI/` owns the Responses transport; `Adapters/LocalAgent/` owns CLI detection, `CLIBrainClient`, the Claude Code and Codex runtimes, and the bounded shared process edge. `LocalAgentRuntimeSet` encapsulates provider-specific coach/summarizer ownership. `AgentCLIProcessRunner` remains only for the explicit completed-session evaluator. The subsystem also owns provider-boundary failure classification (`BrainFailure`), immutable `BrainTarget`/`BrainRoute`, `BrainProvider`, `BrainModelCatalog` (first per-provider entry is the default), and `ReasoningEffort`.
- `Sources/JarvisCore/Coach/` — the event loop: `CoachDriver` (fresh-attempt scheduling and one-target tool-loop orchestration), the pure forward-only `BrainRouteSession`, `SpeechActivityGate`, `CoachHistory` (client-managed session memory), `ToolDefs` (coach tools + system prompt).
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection, substance classification, and silence backoff (`Trigger`, `TurnSubstance`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-triggered screen-capture tool contract + window-scoped capture logic, plus `ScreenCaptureRunner`, which owns each cancellable `screencapture` helper and the transient JPEG it writes into the owner-only session directory: it verifies that file is gone before returning, and a capture whose cleanup can't be proven latches the runner so no later capture (or display fallback) starts while a screen-derived file is unaccounted for (`ScreenCapture`, `ScreenCaptureRunner`, `ScreenSnapshot`, `FrontWindowSelector`, `RecognizedTextLayout`).
- `Sources/JarvisCore/Overlay/` — overlay text model + length-proportional timing + fan-out (`OverlayRendering`, `OverlayTiming`, `OverlayAppearance`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — config + owner-only secrets + brain/screen preferences (`Config`, `Secrets`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`).
- `Sources/JarvisCore/Support/` — small shared runtime primitives (`Clock`, `TurnTaskBox`, `RetrySchedule`, `RetryIncident`).
- `Sources/JarvisCore/Diagnostics/` — logging, always-on activity log with stable persisted event kinds and fixed typed brain-change/failure notices, privacy-preserving audio continuity evidence, session-history store, wire-level brain traffic capture + the read-only agentic audit over the complete session directory, user-facing errors (`ActivityLog`, `AudioContinuityWitness`, `SessionStore`, `BrainTrafficLog`, `EvaluationTranscript`, `AgenticEvaluation`, `AgenticEvaluator`, `UserFacingError`).
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point, connection-aware menu status, Start/Stop, `ErrorReporter` (startup alerts plus an unconditional no-presentation runtime policy).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + sample-preserving system-audio capture with AEC3 echo cancellation + resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `Resampler`), Realtime item/readiness/liveness/transactional-reconnect/witness handling (`RealtimeTranscriber`, `NetworkPathDiagnostics`), permissions, plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting Brain (minimal Provider route / Reasoning effort / Transcription groups) / Overlay / Screen / Activity sections).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer, with an exact selectable/copyable session ID and one-click **Evaluate** / **Open report** agentic audit flow.
- `Sources/EvalPrep/main.swift` — the Foundation-only terminal entry point for the same `AgenticEvaluator` Activity invokes; `scripts/eval-session.sh` runs it over the repo + session dir.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 C edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).
- `.github/workflows/release.yml` + `scripts/package-app.sh` — automated releases: release-please Release PR → Developer ID-signed, notarized, stapled `Jarvis-<version>.zip` attached to a GitHub Release ([build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci)).

## Not yet built

- **First notarized release** — the release workflow needs its five repo secrets (Developer ID `.p12` + App Store Connect API key; names in `.github/workflows/release.yml`) set before the first Release PR is merged; the first run is the pipeline's live test.
- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Minimum macOS version confirmed** — currently targeting macOS 14+; confirm against the APIs actually used (ScreenCaptureKit needs 13+).
