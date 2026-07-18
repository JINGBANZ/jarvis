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
those providers and keeps the OpenAI API-key path available.

## Next action

Run the live prompt smoke on a fresh session: show an interview question without speaking its
details, ask “Jarvis, how can I solve this in one pass?”, and confirm the first action is
exactly one `capture_screen` followed by a screen-specific reply. Then ask a fully stated behavioral
question and confirm it can answer without an unnecessary capture. Finish the remaining in-app CLI provider
smoke: select a detected Claude Code or Codex provider, confirm a coaching turn and screen request,
and confirm a missing CLI fails Start loudly. The standard release checklist remains in
[build-and-run.md](./build-and-run.md).

## Built

Tested `JarvisCore` + `JarvisOverlay` harness is green (`./scripts/run-tests.sh`); `JarvisApp` is the
thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — transactional PCM + utterance buffering, adaptive content-free activity detection, non-destructive AEC reference alignment, and system-audio timeline preservation (`PCMBuffer`, `UtteranceBuffer`, `PCM16Framer`, `AudioDownmix`, `AdaptiveAudioActivityDetector`, `EchoReferenceAlignment`, `SystemAudioTimeline`).
- `Sources/JarvisCore/Transcription/` — realtime session wire contract, per-item event ledger, and rolling transcript (`RealtimeSession`, `RealtimeTranscriptionLedger`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Brain/` — the LLM integration: the `BrainClient` contract (`Brain`), `OpenAIBrainClient`, `CLIBrainClient` + `AgentCLIProcessRunner` + `AgentCLIDetector` (the local Claude Code / Codex brain providers), `RetryingBrainClient`, `BrainProvider`, `BrainModelCatalog` (default `gpt-5.5`), `ReasoningEffort`.
- `Sources/JarvisCore/Coach/` — the event loop: `CoachDriver`, `CoachHistory` (client-managed session memory), `ToolDefs` (coach tools + system prompt).
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection, substance classification, and silence backoff (`Trigger`, `TurnSubstance`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-triggered screen-capture tool contract + window-scoped capture logic (`ScreenCapture`, `ScreenSnapshot`, `FrontWindowSelector`, `RecognizedTextLayout`).
- `Sources/JarvisCore/Overlay/` — overlay text model + length-proportional timing + fan-out (`OverlayRendering`, `OverlayTiming`, `OverlayAppearance`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — config + owner-only secrets + brain/screen preferences (`Config`, `Secrets`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`).
- `Sources/JarvisCore/Diagnostics/` — logging, always-on activity log, privacy-preserving audio continuity evidence, session-history store, wire-level brain traffic capture + one-click session evaluation, user-facing errors (`ActivityLog`, `AudioContinuityWitness`, `SessionStore`, `BrainTrafficLog`, `SessionEvaluator`, `UserFacingError`).
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point, connection-aware menu status, Start/Stop, `ErrorReporter` (severity-driven `NSAlert`).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + sample-preserving system-audio capture with AEC3 echo cancellation + resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `Resampler`), Realtime item/readiness/liveness/transactional-reconnect/witness handling (`RealtimeTranscriber`, `NetworkPathDiagnostics`), permissions, plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting Brain (provider + model + API key) / Overlay / Screen / Activity sections).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer, with the one-click **Evaluate** session audit.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 C edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).

## Not yet built

- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Minimum macOS version confirmed** — currently targeting macOS 14+; confirm against the APIs actually used (ScreenCaptureKit needs 13+).
