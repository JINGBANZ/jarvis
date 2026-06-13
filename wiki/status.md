# Status

> Entry point for anyone (human or agent) joining mid-stream. Updated as the project moves.

## Phase

**Design — complete and approved in substance; spec being finalized.** No application code
written yet. The next step after the spec is reviewed is to produce an implementation plan,
then build on the Mac.

## What's Decided

- **What it is:** a personal LeetCode-coaching "Jarvis" for macOS. Hears you think aloud,
  watches your screen *on demand*, proactively offers short coaching tips via an overlay.
- **Scope:** personal tool first (see [0002](./decisions/0002-personal-tool-first.md)). No
  auth/billing/onboarding. MVP is the whole thing, target < 2 days of autonomous build.
- **Stack:** native Swift/SwiftUI menu-bar app (see [0003](./decisions/0003-native-swift-stack.md)).
- **Brain:** `gpt-5.5` with tool-use + vision (latest flagship). **Transcription:** `gpt-realtime-2`
  (latest realtime model, on the GA Realtime API). API-only, no local models.
- **Screen capture is a model-invoked tool** (see [0005](./decisions/0005-model-triggered-screen-capture.md)).
- **One mode only: LeetCode Coach.** No tiers/mode selector (see [0006](./decisions/0006-single-coach-mode.md)).
- **Overlay:** at most 3 sentences per response, each shown ~5 seconds.
- **Where it's built:** on the MacBook, in a **separate restricted (Standard, non-admin) macOS
  user account — a HARD REQUIREMENT** to protect the user's main account/files from the autonomous
  build agent (see [sandbox.md](./sandbox.md#2-restricted-macos-user-account-development--run--hard-requirement)).
  *Not* on the VPS (see [0004](./decisions/0004-build-on-mac-not-vps.md)). This session/repo (on the
  VPS) is for design and code authoring; the build + verify loop must run on macOS.

## Open Decision

- **Fork vs. greenfield.** Evaluated 6 open-source bases at the code level (see
  [fork-evaluation.md](./fork-evaluation.md)). Top three: Natively (active, already proactive,
  AGPL, large), Glass (OpenAI-native, stale), Pluely (Tauri/Rust, needs streaming-STT rework).
  None have model tool-calling. User leans Natively but is reconsidering native Swift
  ([0003](./decisions/0003-native-swift-stack.md)). Also checking commercial products Final Round
  AI / LockedIn AI / Interview Coder. **Not yet decided.**

## Open Questions / To Confirm

- ~~Exact OpenAI model IDs~~ **Resolved:** brain = `gpt-5.5`, transcription = `gpt-realtime-2`.
  Still re-confirm the exact IDs against live OpenAI docs at build time, and check whether
  `gpt-realtime-2` accepts image input (if so, the brain and transcription roles may merge).
- ~~Whether system-audio (both-sides) capture is in the MVP or deferred~~ **Resolved:** system
  audio is **in** the MVP, as long as it doesn't risk the 2-day timeline. Mic remains the critical
  path; system audio rides along via ScreenCaptureKit and is the first thing cut if the budget is
  threatened. See [specification.md](./specification.md#6-audio-sources).
- Minimum macOS version target (drives which capture APIs are available).

## Next Action

1. User reviews this wiki.
2. Produce the implementation plan (writing-plans).
3. Sync the repo to the MacBook and run the autonomous build there.
