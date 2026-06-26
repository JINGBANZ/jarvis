# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`CLAUDE.md`](./CLAUDE.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page. The load-bearing
> design decisions live in [`decisions.md`](./decisions.md).

## Current phase

**Build complete (headless) — awaiting the live smoke run.** The native Swift app builds, signs with
the stable `Jarvis Dev` identity, and launches, and the full tested harness is green. The OS-bound edges
(mic + system-audio capture, the realtime transcriber, TCC grants, the live brain/transcription
round-trips with a real key and model IDs) compile and launch but are verified only by the human smoke
run.

## Next action

Run the **human smoke run** — build, run, and validate live:

1. `./scripts/build-app.sh release` → `open ./Jarvis.app`; grant Microphone + Screen Recording
   (one-time; they persist afterward — see [build-and-run.md](./build-and-run.md)).
2. Paste your OpenAI key via the menu bar ("Set OpenAI API Key…") — it saves to an owner-only file. Jarvis
   does **not** auto-start; press **Start Jarvis** in the menu to begin (⚪️ stopped → 🟢 running),
   **Stop Jarvis** to halt. Model IDs are doc-verified; no edit expected.
3. Run the **live smoke checklist** ([README](../README.md#live-smoke-checklist)): speak →
   transcript; "I'm stuck on two-sum" → coaching overlay + observed `capture_screen`; overlay
   excluded from the screenshot; while you talk steadily Jarvis stays mostly quiet (model restraint,
   not a rate cap) and **Stop Jarvis** halts the pipeline. (Run via `./scripts/build-app.sh --run`,
   then open Settings → Activity to watch each step.)
4. **The one untested-headlessly edge:** the bare-WebSocket connect for a transcription-only Realtime
   session. The connect contract (`?intent=transcription`, the `session.update` payload) lives in
   `Sources/JarvisCore/Transcription/RealtimeSession.swift`; if the live connect fails, that's the file
   to adjust (e.g. swap `transcriptionModel` in `Config.swift`).

## Built

Tested `JarvisCore` + `JarvisOverlay` harness is green (`./scripts/run-tests.sh`); `JarvisApp` is the
thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — PCM + utterance buffering (`PCMBuffer`, `UtteranceBuffer`, `PCM16Framer`, `AudioDownmix`).
- `Sources/JarvisCore/Transcription/` — realtime session wire contract + rolling transcript (`RealtimeSession`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Coach/` — the event loop and brain client: `CoachDriver`, `OpenAIBrainClient`, `ToolDefs`, `BrainModelCatalog` (default `gpt-5.5`), `ReasoningEffort`.
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection + silence backoff (`Trigger`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/ScreenCapture.swift` — the model-triggered screen-capture tool contract.
- `Sources/JarvisCore/Overlay/` — overlay text model + length-proportional timing + fan-out (`OverlayRendering`, `OverlayTiming`, `OverlayAppearance`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — config + owner-only secrets + brain preferences (`Config`, `Secrets`, `BrainPreferences`).
- `Sources/JarvisCore/Diagnostics/` — logging, always-on activity log, session-history store, user-facing errors (`ActivityLog`, `SessionStore`, `UserFacingError`).
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point, menu bar, Start/Stop, `ErrorReporter` (severity-driven `NSAlert`).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + system-audio capture with AEC3 echo cancellation + resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `Resampler`, `RealtimeTranscriber`, `Permissions`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting API-key / Overlay / Brain / Activity sections).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 C edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).

## Not yet built

- **Live smoke run verified** — the one remaining gate before "done"; see Next action.
- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Minimum macOS version confirmed** — currently targeting macOS 14+; confirm against the APIs actually used (ScreenCaptureKit needs 13+).
