# Status

> Entry point for anyone (human or agent) joining mid-stream. Updated as the project moves.

## Phase

**Building — Phase 2 native Swift app, directly.** The Phase-1 Natively fork PoC was **skipped**
(decision 2026-06-14): we build the keeper once. An implementation plan
([plan-phase2-build.md](./plan-phase2-build.md)) drives an autonomous Claude Code build running on
the Mac.

## What's Decided

- **What it is:** a personal LeetCode-coaching "Jarvis" for macOS. Hears you think aloud,
  watches your screen *on demand*, proactively offers short coaching tips via an overlay.
- **Brain:** `gpt-5.5` with tool-use + vision. **Transcription:** `gpt-realtime-2` (GA Realtime
  API). API-only, no local models.
- **Overlay:** at most 3 sentences per response, each shown ~5 seconds.
- **Build approach: native Swift, directly.** The two-phase plan (fork Natively first, then native)
  was dropped: **Phase 1 is skipped** and we build the clean native Swift app now. The fork
  evaluation and survey still stand as the *why-build-our-own* basis ([fork evaluation](./fork-evaluation.md),
  [survey](./landscape-survey.md) — none usable: closed, paid, answer-dumping; LockedIn AI is the
  best behavior reference), but Natively is now at most a reference, not a base.
- **Toolchain:** **SwiftPM + the Command Line Tools**, *no full Xcode required* — the CLT SDK ships
  ScreenCaptureKit, AVFoundation, AppKit, SwiftUI, Vision, CoreAudio. The app is packaged into a
  `.app` bundle by hand and **ad-hoc signed** (`codesign -s -`); macOS **TCC prompts** grant Screen
  Recording + Microphone at first run (in place of formal App-Sandbox entitlements). See
  [specification.md](./specification.md#9-build--run-constraints).
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
| **One mode for v1: LeetCode Coach** (no tiers) | [specification.md](./specification.md) |
| **Model-triggered `capture_screen`** (tool-use loop; cheaper + smarter) | [architecture.md](./architecture.md), [specification.md](./specification.md) |
| **Models:** `gpt-5.5` brain (vision), `gpt-realtime-2` transcription | [specification.md](./specification.md) |
| **Coach is time-aware** (timestamped transcript + silence duration) | [specification.md](./specification.md) |
| **System audio in the MVP** (budget-permitting; mic is the critical path) | [specification.md](./specification.md) |
| ~~Two-phase build~~ → **Skip Phase 1; build native Swift directly** (2026-06-14) | this page; [fork-evaluation.md](./fork-evaluation.md) |
| **Native Swift app** (cleanest sandbox/footprint on macOS) | [architecture.md](./architecture.md), [fork-evaluation.md](./fork-evaluation.md) |
| **Toolchain: SwiftPM + Command Line Tools** (no full Xcode; manual bundle + ad-hoc sign; TCC prompts) | [specification.md](./specification.md#9-build--run-constraints) |
| ~~Build in a separate restricted account (HARD)~~ → **build in main `forrest` account, in a git worktree; hard requirement waived for the personal build** (2026-06-14) | [sandbox.md](./sandbox.md) |

## Open Questions / To Confirm

- ~~Exact OpenAI model IDs~~ **Resolved:** brain = `gpt-5.5`, transcription = `gpt-realtime-2`.
  Still re-confirm the exact IDs against live OpenAI docs at build time, and check whether
  `gpt-realtime-2` accepts image input (if so, the brain and transcription roles may merge).
- ~~Whether system-audio (both-sides) capture is in the MVP or deferred~~ **Resolved:** system
  audio is **in** the MVP, as long as it doesn't risk the 2-day timeline. Mic remains the critical
  path; system audio rides along via ScreenCaptureKit and is the first thing cut if the budget is
  threatened. See [specification.md](./specification.md#6-audio-sources).
- Minimum macOS version target. Build host is macOS 26.5; ScreenCaptureKit screen+audio capture
  needs macOS 13+. Target **macOS 14+** unless a needed API forces higher.
- Whether ad-hoc signing lets the TCC Screen-Recording/Microphone grants *persist* across rebuilds
  (a stable bundle path + signature usually suffices; confirm on the live smoke run).

## Next Action

The build is driven by [plan-phase2-build.md](./plan-phase2-build.md):

1. Scaffold the SwiftPM package + test harness; implement components TDD-first (Transcriber,
   CoachDriver + guardrails, tools, Overlay, AudioInput, MenuBar).
2. Run unit + offline-pipeline tests (mock OpenAI client); confirm the `.app` bundle builds,
   ad-hoc signs, and launches.
3. **Human-in-the-loop (deferred to Forrest):** enter a real OpenAI key, grant Screen-Recording +
   Microphone at first run, and run the **live smoke checklist**
   ([specification.md §8](./specification.md#8-self-verification-plan)).
