# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edit it only when
> one of its sections changes, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist"; a behavior
> change updates its design page, not this one. Every file pointer below either resolves to a real
> file or this page is wrong — fix the page.

## Current phase

**Released and hardening.** Jarvis coaches live technical interviews end to end, from two-speaker
transcription through an ordered brain route with on-demand skills and tools to private
capture-excluded overlays, and ships as a signed, notarized Apple silicon release.

## Next action

Run the browser screen-text check in a development bundle, following
[build-and-run.md → Browser screen-text validation](./build-and-run.md#browser-screen-text-validation):
real Chrome coverage is the remaining acceptance check for bounded screen context. The other manual
checks, each with the change that calls for it, are in
[live-e2e-tests.md → What stays outside the command](./live-e2e-tests.md#what-stays-outside-the-command).

## Built

Each entry is one top-level area; its design lives on the linked page. The offline Gate tests every
target except `JarvisApp`, which the [live e2e run](./live-e2e-tests.md) verifies.

- `Sources/JarvisCore/Audio/`: PCM buffering, speech activity detection, and echo-reference alignment for both capture streams.
- `Sources/JarvisCore/Transcription/`: provider-neutral transcription contracts, the OpenAI Realtime and Gemini Live wire contracts, reconnect recovery, and the spoken-time conversation chronology ([architecture.md → Models and APIs](./architecture.md#models-and-apis)).
- `Sources/JarvisCore/Benchmark/` + `Sources/JarvisApp/Benchmark/`: the transcription benchmark matrix, scoring, and signed-app runner ([transcription-benchmark.md](./transcription-benchmark.md)).
- `Sources/JarvisCore/LiveE2E/` + `Sources/JarvisApp/LiveE2E/`: the debug-only live e2e scenario model and signed-app mode ([live-e2e-tests.md](./live-e2e-tests.md)).
- `Tests/JarvisLiveTests/` + `scripts/run-live-tests.sh` + `scripts/run-browser-capture-check.sh`: the live scenario checker and explicit signed-app Chrome capture check ([live-e2e-tests.md](./live-e2e-tests.md)); the Gate compiles the live target but never runs it.
- `Sources/JarvisCore/Brain/`: the provider-neutral brain domain: client and attempt-scoped conversation contracts, route targets, and the model catalog.
- `Sources/JarvisCore/Providers/`: provider failure classification, redaction, and credential checks shared by brain, transcription, and Settings.
- `Sources/JarvisBrainProviders/`: the concrete brain adapters: the Responses client, the bundled subscription helper's supervisor and sign-in, and the CLI detector and runner the session evaluator uses ([architecture.md → Subscription targets through the bundled proxy](./architecture.md#subscription-targets-through-the-bundled-proxy)).
- `Sources/JarvisCore/Coach/`: the coaching loop, where `CoachDriver` schedules attempts and `CoachAttemptRunner` runs one, with route state, session memory, capabilities, and one file per coach tool ([architecture.md → Core Loop](./architecture.md#2-core-loop)).
- `Sources/JarvisCore/Triggers/`: turn and silence triggers and silence backoff.
- `Sources/JarvisCore/PrepMaterial/` + `Sources/JarvisApp/PrepMaterial/`: prep-material chunking, indexing, and search behind `search_prep_notes` ([architecture.md → Capabilities](./architecture.md#capabilities)).
- `Sources/JarvisCore/Screen/`: the model-facing screen port, front-window selection, and OCR layout.
- `Sources/JarvisScreenCapture/`: the OS-bound screen-capture adapter, combining the `screencapture` helper, browser Accessibility text, and OCR ([settings-window.md → Capture Scope](./settings-window.md#capture-scope)).
- `Sources/JarvisCore/Overlay/`: the overlay output port, with its text model, timing, code snippets, and diagram hints ([overlay-timing.md](./overlay-timing.md)).
- `Sources/JarvisCore/Config/` + `Sources/JarvisCore/Resources/Skills/`: preferences, owner-only secrets, the immutable `SessionPlan`, and the bundled coaching skills.
- `Sources/JarvisCore/Support/`: small shared runtime primitives.
- `Sources/JarvisCore/Diagnostics/`: session evidence, Activity, readiness, capture health, and session history ([session-audit.md](./session-audit.md)).
- `Sources/JarvisCore/Prompts/`: the predefined model-facing text.
- `Sources/JarvisEvaluation/`: sealed-session evaluation, from evidence parsing and metrics to the agentic evaluator and its report.
- `Sources/JarvisOverlay/`: the capture-excluded caption and box panels and their chrome ([overlay-invisibility.md](./overlay-invisibility.md)).
- `Sources/JarvisApp/App/` + `Sources/JarvisApp/MenuBar/`: the entry point, Start and Stop, and the session, brain, and artifact composition owners ([lean-coaching-core.md](./lean-coaching-core.md)).
- `Sources/JarvisApp/Capture/`: microphone and system-audio capture with AEC3 and Silero VAD, the transcription provider adapters, permissions, and the window screenshot edge.
- `Sources/JarvisApp/Onboarding/`: the launch permission gate ([architecture.md → Permissions](./architecture.md#permissions)).
- `Sources/JarvisApp/Settings/`: the Settings window ([settings-window.md](./settings-window.md)).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift`: the global coaching shortcuts.
- `Sources/JarvisApp/Updates/UpdateController.swift`: the **Check for Updates** menu item ([build-and-run.md → In-app updates](./build-and-run.md#in-app-updates--sparkle-over-the-release-feed)).
- `Sources/JarvisApp/Viewer/ActivityViewer.swift`: the Activity window and its **Evaluate** flow ([build-and-run.md → The live activity viewer](./build-and-run.md#the-live-activity-viewer)).
- `Sources/EvalPrep/main.swift` + `scripts/eval-session.sh`: the terminal entry point for the same evaluator.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a`: the prebuilt WebRTC AEC3 archive, rebuilt by `scripts/build-aec.sh`.
- `Sources/JarvisApp/Resources/SileroVAD.mlmodelc`: the Silero VAD model, rebuilt by `scripts/build-vad.sh`.
- `scripts/build-app.sh` + `scripts/lib/cliproxyapi.sh`: the local `Jarvis Dev.app` build and the pinned subscription helper both app builds bundle ([build-and-run.md](./build-and-run.md)).
- `.github/workflows/` + `scripts/package-app.sh`: CI, agent automation, and the signed, notarized release pipeline ([build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci), [sandbox.md → Repository automation](./sandbox.md#repository-automation)).
- `AGENTS.md` + `.github/workflows/sync-shared-rules.yml`: agent guidance whose shared-rules block syncs weekly from `JINGBANZ/rules`.

## Not yet built

- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
- **Gemini Live session resumption** (`sessionResumptionUpdate`) — `GeminiLiveTranscriber` drains and
  rotates ahead of the ~10-minute `goAway` close ([architecture.md → Resilience](./architecture.md#resilience)),
  which recovers the common case, but a single utterance long enough to still be in progress exactly
  when the bounded grace period elapses can still be split across the rotation. Google's own session
  resumption is the complete fix; adopting it is deliberately left as a follow-up rather than bundled
  into the drain.
