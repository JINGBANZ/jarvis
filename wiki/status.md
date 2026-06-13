# Status

> Entry point for anyone (human or agent) joining mid-stream. Updated as the project moves.

## Phase

**Design — complete and approved in substance; spec being finalized.** No application code
written yet. The next step after the spec is reviewed is to produce an implementation plan,
then build on the Mac.

## What's Decided

- **What it is:** a personal LeetCode-coaching "Jarvis" for macOS. Hears you think aloud,
  watches your screen *on demand*, proactively offers short coaching tips via an overlay.
- **Brain:** `gpt-5.5` with tool-use + vision. **Transcription:** `gpt-realtime-2` (GA Realtime
  API). API-only, no local models.
- **Overlay:** at most 3 sentences per response, each shown ~5 seconds.
- **Build approach: two-phase.** Phase 1 forks **Natively** for a fast proactive-coach PoC (swap
  models, retarget its proactive trigger to LeetCode coaching + timing, add the coach prompt, short
  ephemeral overlay; the `capture_screen` tool-loop is deferred). Phase 2, *if validated*, is the
  clean native Swift app using Natively as a reference. Basis: the code-level
  [fork evaluation](./fork-evaluation.md) of 6 bases + the commercial-product
  [survey](./landscape-survey.md) (none usable — closed, paid, answer-dumping; LockedIn AI is the
  best behavior reference).
- **Where it's built:** on the MacBook, in a **separate restricted (Standard, non-admin) macOS
  user account — a HARD REQUIREMENT** to protect the user's main account/files from the autonomous
  build agent (see [sandbox.md](./sandbox.md)). *Not* on the VPS (can't compile/test the macOS APIs
  there). This session/repo on the VPS is for design and code authoring only.

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
| **Two-phase build:** fork Natively PoC, then native Swift if validated | [fork-evaluation.md](./fork-evaluation.md); this page |
| **Native Swift for the Phase-2 app** (cleanest sandbox/footprint on macOS) | [architecture.md](./architecture.md), [fork-evaluation.md](./fork-evaluation.md) |
| **Build on the Mac, in a separate restricted account** (HARD requirement) | [sandbox.md](./sandbox.md) |

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

1. Produce the **Phase 1 implementation plan** (fork Natively → proactive LeetCode-coach PoC).
2. On the MacBook: create the separate restricted `jarvisbuild` account, clone Natively there,
   confirm the base app builds and its both-sides audio + overlay work.
3. Execute the Phase 1 plan; smoke-test the proactive coaching experience.
4. Decide whether to proceed to Phase 2 (native Swift).
