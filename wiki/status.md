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
those providers, reports Claude's current sign-in state from its bounded status command, and keeps
the OpenAI API-key path available. Provider, model, and effort changes apply transactionally between
turns without restarting the session: the previous brain remains available until the replacement
finishes a non-truncated terminal turn, and Activity records a fixed provider-only success or
fallback notice. Codex coaching calls suppress project instructions and its feature-gated agent
tools, run as direct-response decisions, inherit only stable executable-search paths, and stop under
a provider-specific stall bound instead of leaving later speech batched indefinitely. Brain
providers share one recoverability policy across adapter, immediate retry, and lifecycle:
temporary or unknown failures miss one turn but preserve the transcript, pending triggers, history,
capture, and transcription for the next attempt; only an explicitly permanent failure stops.
Saving an API key while running also preserves those live objects: existing Realtime sockets take
the key on their next reconnect, and an OpenAI brain update remains transactional. Audio
route rebuilds likewise retry before declaring capture unavailable, and stale capture callbacks
cannot stop a replacement session; repeated route notifications cannot reset one incident's bounded
budget. Activity persists stable event kinds and flushes before evaluation, so both evaluator paths
include failure/degrade outcomes even if their human-facing copy changes or evaluation is clicked
immediately after Stop. The same runtime ghost-mode rule
now covers microphone transcription, audio-route loss, in-place CLI preflight, and Activity-audit
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
the previous provider continues the conversation with a provider-only fallback notice. Finish the
in-app Codex smoke through audio and the overlay, then confirm a missing or signed-out CLI fails
loudly. Exercise one forced temporary brain miss and one audio-route switch: Activity should say
listening continues, the next turn should include the unsent speech, and capture should recover
without rotating the session. The standard release checklist remains in
[build-and-run.md](./build-and-run.md).

## Built

Tested `JarvisCore` + `JarvisOverlay` harness is green (`./scripts/run-tests.sh`); `JarvisApp` is the
thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — transactional PCM + utterance buffering, adaptive content-free activity detection, non-destructive AEC reference alignment, and system-audio timeline preservation (`PCMBuffer`, `UtteranceBuffer`, `PCM16Framer`, `AudioDownmix`, `AdaptiveAudioActivityDetector`, `EchoReferenceAlignment`, `SystemAudioTimeline`).
- `Sources/JarvisCore/Transcription/` — realtime session wire contract, per-item event ledger, and rolling transcript (`RealtimeSession`, `RealtimeTranscriptionLedger`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Brain/` — the LLM integration: the `BrainClient` contract (`Brain`), `OpenAIBrainClient`, `CLIBrainClient` + `AgentCLIProcessRunner` + `AgentCLIDetector`/`AgentCLIAuthenticationStatus` (the local Claude Code / Codex brain providers and sign-in state), shared retry/lifecycle classification (`BrainFailure`), `RetryingBrainClient`, `BrainProvider`, `BrainModelCatalog` (default `gpt-5.5`), `ReasoningEffort`.
- `Sources/JarvisCore/Coach/` — the event loop: `CoachDriver` (including transactional between-turn brain replacement), `CoachHistory` (client-managed session memory), `ToolDefs` (coach tools + system prompt).
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection, substance classification, and silence backoff (`Trigger`, `TurnSubstance`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-triggered screen-capture tool contract + window-scoped capture logic (`ScreenCapture`, `ScreenSnapshot`, `FrontWindowSelector`, `RecognizedTextLayout`).
- `Sources/JarvisCore/Overlay/` — overlay text model + length-proportional timing + fan-out (`OverlayRendering`, `OverlayTiming`, `OverlayAppearance`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — config + owner-only secrets + brain/screen preferences (`Config`, `Secrets`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`).
- `Sources/JarvisCore/Support/` — small shared runtime primitives (`Clock`, `TurnTaskBox`, `RetrySchedule`, `RetryIncident`).
- `Sources/JarvisCore/Diagnostics/` — logging, always-on activity log with stable persisted event kinds and fixed typed brain-change/failure notices, privacy-preserving audio continuity evidence, session-history store, wire-level brain traffic capture + one-click session evaluation (single-call in-app **and** the agentic dev-side audit's prompt/transcript prep, both including Activity outcomes), user-facing errors (`ActivityLog`, `AudioContinuityWitness`, `SessionStore`, `BrainTrafficLog`, `SessionEvaluator`, `AgenticEvaluation`, `UserFacingError`).
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point, connection-aware menu status, Start/Stop, `ErrorReporter` (startup alerts plus an unconditional no-presentation runtime policy).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + sample-preserving system-audio capture with AEC3 echo cancellation + resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `Resampler`), Realtime item/readiness/liveness/transactional-reconnect/witness handling (`RealtimeTranscriber`, `NetworkPathDiagnostics`), permissions, plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting Brain (provider + model + API key) / Overlay / Screen / Activity sections).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer, with an exact selectable/copyable session ID and the one-click **Evaluate** session audit.
- `Sources/EvalPrep/main.swift` — the Foundation-only CLI half of the agentic session audit; `scripts/eval-session.sh` drives it through an agentic CLI (`claude -p` / `codex exec`) over the repo + session dir (see the 2026-07-17 [decision](./decisions.md)).
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 C edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).
- `.github/workflows/release.yml` + `scripts/package-app.sh` — automated releases: release-please Release PR → Developer ID-signed, notarized, stapled `Jarvis-<version>.zip` attached to a GitHub Release ([build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci)).

## Not yet built

- **First notarized release** — the release workflow needs its five repo secrets (Developer ID `.p12` + App Store Connect API key; names in `.github/workflows/release.yml`) set before the first Release PR is merged; the first run is the pipeline's live test.
- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Minimum macOS version confirmed** — currently targeting macOS 14+; confirm against the APIs actually used (ScreenCaptureKit needs 13+).
