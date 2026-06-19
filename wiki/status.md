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
  session for multi-turn memory. **Transcription:** `gpt-4o-transcribe` over the GA Realtime API.
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

## Key Decisions

A compact log — the *rationale* for each lives in the linked design page, not here.

| Decision | Where the detail lives |
|---|---|
| **Build our own** (no maintained tool does proactive speak-up well) | [landscape-survey.md](./landscape-survey.md), [fork-evaluation.md](./fork-evaluation.md) |
| **Personal tool first** (no auth/billing; freely reuse open code; <2-day MVP) | this page; [architecture.md](./architecture.md) |
| **Proactive, unprompted** coaching is the core differentiator (no hotkey) | [architecture.md](./architecture.md) |
| **One mode for v1: LeetCode Coach** (no tiers) | [architecture.md](./architecture.md#6-non-goals-v1) |
| **Model-triggered `capture_screen`** (tool-use loop; cheaper + smarter) | [architecture.md](./architecture.md#2-core-loop) |
| **Models (verified 2026-06):** `gpt-5.5` brain via Responses API (vision), `gpt-4o-transcribe` over GA Realtime | [architecture.md](./architecture.md#models-and-apis) |
| **Server-side conversation per session** (Conversations API, `store:true`) for the coach's own memory — quality over local-only retention | [architecture.md](./architecture.md#models-and-apis), [sandbox.md](./sandbox.md) |
| **Coach is time-aware** (timestamped transcript + silence duration) | [architecture.md](./architecture.md#2-core-loop) |
| **System audio shipped** — `SystemAudioInput` (ScreenCaptureKit) → a second `them`-tagged transcriber beside the mic's `me`, one shared transcript (2026-06-16) | [architecture.md](./architecture.md#3-components) |
| ~~Two-phase build~~ → **Skip Phase 1; build native Swift directly** (2026-06-14) | this page; [fork-evaluation.md](./fork-evaluation.md) |
| **Native Swift app** (cleanest sandbox/footprint on macOS) | [architecture.md](./architecture.md), [fork-evaluation.md](./fork-evaluation.md) |
| **Toolchain: SwiftPM + Command Line Tools** (no full Xcode; manual bundle + stable self-signed `Jarvis Dev` identity so TCC grants persist; TCC prompts) | [build-and-run.md](./build-and-run.md) |
| ~~Build in a separate restricted account (HARD)~~ → **build in main `forrest` account, in a git worktree; hard requirement waived for the personal build** (2026-06-14) | [sandbox.md](./sandbox.md) |
| **Tuned `server_vad`+debounce (not `semantic_vad`); quiet graceful Stop** — fixes from first live smoke run (2026-06-15) | [architecture.md](./architecture.md#models-and-apis) |
| **Dev activity viewer = in-app `WKWebView`** (live push, no meta-refresh; screenshot lightbox; persisted JSONL session history + clear-history) | [build-and-run.md](./build-and-run.md) |
| **Overlay hidden from screen capture/sharing via `sharingType = .none`** — verified on macOS 26.5 incl. live `SCStream`; re-asserted on `show()` as defense-in-depth | [overlay-invisibility.md](./overlay-invisibility.md) |
| **Cut the guardrail layer: no cooldown/rate cap, no wake-word detector; brain self-gates speaking; silence check backs off across a long silence** — simplify the flow, cut log noise, natural conversation (2026-06-16) | [architecture.md §5](./architecture.md#5-safety-model) |
| **`speak` returns a `lines` array via Structured Outputs (`strict:true`), not a free-form string** — the model splits the tip into overlay lines, so the client no longer splits prose on `.`/`!`/`?` (which shattered code like `Array.from(...)`) (2026-06-17) | [architecture.md §2](./architecture.md#2-core-loop) |
| **Unified Settings window** replaces the separate API-key dialog and log-viewer menu item; overlay text size (12–32 pt, default 18) + background opacity (40–100%, default 78%) are now user-adjustable and persisted via `OverlayAppearance` (UserDefaults) (2026-06-17) | [settings-window.md](./settings-window.md) |
| **Tuned overlay/silence timing + sharpened coach prompt** — longer per-line overlay display, later first silence nudge over a wider backoff ramp, plain-language hints for interview stress, explicit `me`/`them` speaker handling; overlay now **queues** tips so a newer one never cuts off the current (2026-06-18) | [architecture.md §2](./architecture.md#2-core-loop) |
| **Overlay is never-interrupt + never-drop, not show-freshest** — direct-reply queue-priority/preemption considered and **rejected**: in a live interview the user never addresses Jarvis aloud, so overlay traffic is all proactive coaching with no latency-critical reply to jump the queue (2026-06-18) | [architecture.md §2](./architecture.md#2-core-loop) |
| **AEC reverted — mic was silent** — `VoiceProcessingIO` came up without throwing, but the `SCStream` starting ~150 ms later changed the audio route out from under it and the mic went silent (RMS 0); reverted to a plain `AVAudioEngine` tap (2026-06-18) | [architecture.md §3](./architecture.md#3-components) |
| **Echo cancellation via one-clock Core Audio aggregate device + AEC3 — no headphones needed** — the mic was bleeding the other side's speaker audio into the `me` transcript (verbatim, on speakers). Solved by capturing the mic + a system-output **process tap** in ONE private aggregate device (mic = clock master, tap drift-compensated), so a single IOProc delivers both synced at 48 kHz — the meeting-app single-clock case — and AEC3 runs inside that callback. Measured **30–50 dB** cancellation live; the other side no longer mis-transcribes as `me`, the user's own voice is preserved, double-talk works. Replaces the separate `AVAudioEngine` mic + `SCStream`. Path taken after a prior two-clock attempt (separate mic + SCStream feeding AEC3) achieved only ~5% — confirmed by research that a passive bystander on two clocks is the hard async-AEC case; one aggregate device removes the drift. AEC3 lib via `scripts/build-aec.sh` (vendored zero-dylib `.a`). (2026-06-19) | [architecture.md §3](./architecture.md#3-components) |

## Open Questions / To Confirm

- **AEC robustness: mid-session route changes.** The process tap targets the output device at start;
  if the user plugs/unplugs headphones mid-call the tap can go stale. Need an
  `AudioObjectAddPropertyListener` on the default output device to tear down + rebuild the aggregate,
  and to bypass AEC on headphone routes (no acoustic echo). Not yet implemented.
- **Double-talk under loud far audio** can over-attenuate the user briefly (AEC3 limitation); a neural
  canceller (DTLN, Muesli-style) on the same aligned streams is the escalation if it bites in practice.
- **Dead code to remove:** the old `AudioInput` (AVAudioEngine mic) + `SystemAudioInput` (SCStream) are
  superseded by `AggregateEchoCapture`; the SCStream screen-recording priming can go too.
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
2. Paste your OpenAI key via the menu bar ("Set OpenAI API Key…") — it saves to the Keychain. Jarvis
   does **not** auto-start; press **Start Jarvis** in the menu to begin (⚪️ stopped → 🟢 running),
   **Stop Jarvis** to halt. Model IDs are doc-verified; no edit expected.
3. Run the **live smoke checklist** ([README](../README.md#live-smoke-checklist)): speak →
   transcript; "I'm stuck on two-sum" → coaching overlay + observed `capture_screen`; overlay
   excluded from the screenshot; while you talk steadily Jarvis stays mostly quiet (model restraint,
   not a rate cap) and **Stop Jarvis** halts the pipeline. (Run via `./scripts/build-app.sh --dev`,
   then open the activity viewer from the menu bar to watch each step.)
4. **Only remaining live unknown:** the bare-WebSocket connect for a transcription-only Realtime
   session. The connect contract (`?intent=transcription`, the `session.update` payload) lives in
   `RealtimeSession.swift`; if the live connect fails, that's the file to adjust (e.g. swap
   `transcriptionModel` in `Config.swift`).
