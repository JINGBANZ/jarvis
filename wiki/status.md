# Status

> Entry point for anyone (human or agent) joining mid-stream. Updated as the project moves.

## Phase

**Build complete (headless) — awaiting the live smoke run.** Phase 1 was **skipped** (2026-06-14)
and the native Swift app was built directly. The tested harness (config, transcript, silence
backoff, coach tool-loop, OpenAI client, activity log + viewer, session store, overlay invisibility)
is **green**; `Jarvis.app` builds, signs with the stable `Jarvis Dev` identity, and launches. The
app shell, overlay, mic capture, and realtime transcriber **compile and launch**, but their *live*
behavior (real mic, websocket, TCC grants, real `OPENAI_API_KEY`, real model IDs) is verified only
by the human smoke checklist in the [README](../README.md#live-smoke-checklist).

## What's Decided

- **What it is:** a personal LeetCode-coaching "Jarvis" for macOS. Hears you think aloud,
  watches your screen *on demand*, proactively offers short coaching tips via an overlay.
- **Brain:** `gpt-5.5` (Responses API, tool-use + vision), with a server-side conversation per
  session for multi-turn memory. Model + reasoning effort are user-selectable in Settings
  (default `gpt-5.5` / `low`). **Transcription:** `gpt-4o-transcribe` over the GA Realtime API.
  API-only, no local models. Rationale: [architecture.md](./architecture.md#4-data-flow--cost-model).
- **Overlay:** the brain returns the tip as a pre-split `lines` array (Structured Outputs); the
  overlay shows up to ~3 short lines per response, one at a time. Newer tips queue behind the one on
  screen rather than interrupting it, so no hint is dropped.
- **Build approach: native Swift, directly.** The two-phase plan (fork Natively first, then native)
  was dropped: **Phase 1 is skipped** and we build the clean native Swift app now. The fork
  evaluation and survey still stand as the *why-build-our-own* basis ([fork evaluation](./fork-evaluation.md),
  [survey](./landscape-survey.md) — none usable: closed, paid, answer-dumping; LockedIn AI is the
  best behavior reference), but Natively is now at most a reference, not a base.
- **Toolchain:** **SwiftPM + the Command Line Tools**, *no full Xcode required*. The app is packaged
  into a `.app` bundle by hand and signed with a **stable self-signed identity** (`Jarvis Dev`, so
  TCC grants persist across rebuilds); macOS **TCC prompts** grant Screen Recording + Microphone at
  first run. See [build-and-run.md](./build-and-run.md).
- **Where it's built:** on the MacBook, in the **main `forrest` account**, inside a **git worktree**
  for recoverability. The earlier HARD REQUIREMENT to build in a separate restricted account is
  **waived for this personal build** (decision 2026-06-14) — the security tradeoff (unsandboxed app
  could read the main account's files) is accepted for now and documented in
  [sandbox.md](./sandbox.md); the hardened model (App Sandbox + restricted account) is kept there as
  the path for any future shippable version.

## Key decisions

The load-bearing decisions and their rationale live in the dedicated log:
[decisions.md](./decisions.md) (newest last; each entry links to the design page with the detail).

## Open Questions / To Confirm

- **Double-talk under loud far audio** can over-attenuate the user briefly (AEC3 limitation); a neural
  canceller (DTLN, Muesli-style) on the same aligned streams is the escalation if it bites in practice.
  AEC stays ON across all routes (near-passthrough on headphones); we deliberately don't auto-bypass
  on "headphones" because the detection is unreliable (a BT speaker looks like headphones) and a wrong
  bypass re-admits the echo.
- **Universal binary.** `libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 build if Intel is needed.
- Minimum macOS version target. Build host is macOS 26.5; ScreenCaptureKit screen+audio capture
  needs macOS 13+. Target **macOS 14+** unless a needed API forces higher.
- The **live Realtime transcription wiring** in `Sources/JarvisApp/Capture/RealtimeTranscriber.swift` is the
  one thing untested headlessly — the connect/config follow current docs but the bare-WebSocket
  connect for a transcription-only session is unverified until the live run (see Next Action).

## Next Action

The headless build is done. Remaining is the **human smoke run** — build, run, and validate live:

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
4. **Only remaining live unknown:** the bare-WebSocket connect for a transcription-only Realtime
   session. The connect contract (`?intent=transcription`, the `session.update` payload) lives in
   `RealtimeSession.swift`; if the live connect fails, that's the file to adjust (e.g. swap
   `transcriptionModel` in `Config.swift`).
