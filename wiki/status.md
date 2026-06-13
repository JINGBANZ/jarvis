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
- **Brain:** GPT-5.5 with tool-use. **Transcription:** OpenAI Realtime API. API-only, no local models.
- **Screen capture is a model-invoked tool** (see [0005](./decisions/0005-model-triggered-screen-capture.md)).
- **One mode only: LeetCode Coach.** No tiers/mode selector (see [0006](./decisions/0006-single-coach-mode.md)).
- **Overlay:** at most 3 sentences per response, each shown ~5 seconds.
- **Where it's built:** on the MacBook, in a restricted macOS user account — *not* on the VPS
  (see [0004](./decisions/0004-build-on-mac-not-vps.md)). This session/repo (on the VPS) is for
  design and code authoring; the build + verify loop must run on macOS.

## Open Questions / To Confirm

- Exact OpenAI model IDs for the Realtime transcription leg vs. the GPT-5.5 brain leg (confirm
  against current API docs at build time).
- ~~Whether system-audio (both-sides) capture is in the MVP or deferred~~ **Resolved:** system
  audio is **in** the MVP, as long as it doesn't risk the 2-day timeline. Mic remains the critical
  path; system audio rides along via ScreenCaptureKit and is the first thing cut if the budget is
  threatened. See [specification.md](./specification.md#6-audio-sources).
- Minimum macOS version target (drives which capture APIs are available).

## Next Action

1. User reviews this wiki.
2. Produce the implementation plan (writing-plans).
3. Sync the repo to the MacBook and run the autonomous build there.
