# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`CLAUDE.md`](./CLAUDE.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page. The load-bearing
> design decisions live in [`decisions.md`](./decisions.md).

## Current phase

**Realtime reliability hardened headlessly — awaiting live validation.** Earlier live runs verified
the end-to-end pipeline and exposed intermittent startup/mid-session socket losses plus a brain
request timeout. The app now verifies the two real transcription sockets, actively monitors them,
shows connection health in the menu, preserves audio across reconnects, and retries one transient
primary brain failure. The implementation builds and the full tested harness is green; the new
OS/network behavior still needs a human smoke run.

## Next action

Run the **reliability smoke run** from the reliability branch — build, run, and validate live:

1. `./scripts/build-app.sh release` → `open ./Jarvis.app`; grant Microphone + Screen Recording
   (one-time; they persist afterward — see [build-and-run.md](./build-and-run.md)).
2. Paste your OpenAI key via the menu bar ("Set OpenAI API Key…") — it saves to an owner-only file. Jarvis
   does **not** auto-start; press **Start Jarvis** in the menu to begin. Confirm the status progresses
   from Starting to final, unqualified Listening only after both transcription sessions report ready,
   then use **Stop Jarvis** to halt. Model IDs are doc-verified; no edit expected.
3. Run the **live smoke checklist** ([README](../README.md#live-smoke-checklist)): speak →
   transcript; "I'm stuck on two-sum" → coaching overlay + observed `capture_screen`; overlay
   excluded from the screenshot; while you talk steadily Jarvis stays mostly quiet (model restraint,
   not a rate cap) and **Stop Jarvis** halts the pipeline. (Run via `./scripts/build-app.sh --run`,
   then open Settings → Activity to watch each step.)
4. Leave Jarvis silent beyond one health-probe interval, then speak; transcription should still work
   without waiting for speech to discover a dead socket. Toggle Wi-Fi off/on once: the menu should
   show Reconnecting, buffered speech should replay after recovery, and the log should identify the
   `me`/`them` socket plus the macOS network-path state. Confirm two persistent failures degrade to
   microphone-only or stop loudly rather than leaving a false green state.
5. For the brain path, watch Settings → Activity during a transient timeout/network loss: the first
   failure should log one retry and either complete on that retry or fail normally so the next trigger
   carries the unsent transcript. Permanent HTTP failures must not retry.
6. **Brain-input PoC** (window-scoped capture + OCR sidecar — see the 2026-07-07
   [decision](./decisions.md)): with a LeetCode window frontmost, a planted bug, and effort **Low**,
   compare bug-found rate / input tokens / latency across capture scopes (full display vs. active
   window vs. active window + OCR, 5 runs each) to confirm Low+clean-input replaces High.
7. **One-click session evaluation** (see the 2026-07-15 [decision](./decisions.md)): while coaching
   runs, Settings → Activity → **Evaluate** stays disabled for the live session; after Stop it
   enables — click it and expect `brain-traffic.jsonl` in the session dir, the audit report window,
   and `eval-report.md` saved beside the traffic it audits.

## Built

Tested `JarvisCore` + `JarvisOverlay` harness is green (`./scripts/run-tests.sh`); `JarvisApp` is the
thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — PCM + utterance buffering (`PCMBuffer`, `UtteranceBuffer`, `PCM16Framer`, `AudioDownmix`).
- `Sources/JarvisCore/Transcription/` — realtime session wire contract + rolling transcript (`RealtimeSession`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Coach/` — the event loop and brain clients: `CoachDriver`, `OpenAIBrainClient`, `RetryingBrainClient`, `ToolDefs`, `BrainModelCatalog` (default `gpt-5.5`), `ReasoningEffort`.
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection + silence backoff (`Trigger`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-triggered screen-capture tool contract + window-scoped capture logic (`ScreenCapture`, `ScreenSnapshot`, `FrontWindowSelector`, `RecognizedTextLayout`).
- `Sources/JarvisCore/Overlay/` — overlay text model + length-proportional timing + fan-out (`OverlayRendering`, `OverlayTiming`, `OverlayAppearance`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — config + owner-only secrets + brain/screen preferences (`Config`, `Secrets`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`).
- `Sources/JarvisCore/Diagnostics/` — logging, always-on activity log, session-history store, wire-level brain traffic capture + one-click session evaluation, user-facing errors (`ActivityLog`, `SessionStore`, `BrainTrafficLog`, `SessionEvaluator`, `UserFacingError`).
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point, connection-aware menu status, Start/Stop, `ErrorReporter` (severity-driven `NSAlert`).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + system-audio capture with AEC3 echo cancellation + resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `Resampler`), readiness/liveness/reconnect monitoring (`RealtimeTranscriber`, `NetworkPathDiagnostics`), permissions, plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting API-key / Overlay / Brain / Activity sections).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer, with the one-click **Evaluate** session audit.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 C edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).
- `.github/workflows/release.yml` + `scripts/package-app.sh` — automated releases: release-please Release PR → Developer ID-signed, notarized, stapled `Jarvis-<version>.zip` attached to a GitHub Release ([build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci)).

## Not yet built

- **Live validation of the new Realtime reliability behavior** — the remaining gate for this hardening pass; see Next action.
- **First notarized release** — the release workflow needs its five repo secrets (Developer ID `.p12` + App Store Connect API key; names in `.github/workflows/release.yml`) set before the first Release PR is merged; the first run is the pipeline's live test.
- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Minimum macOS version confirmed** — currently targeting macOS 14+; confirm against the APIs actually used (ScreenCaptureKit needs 13+).
