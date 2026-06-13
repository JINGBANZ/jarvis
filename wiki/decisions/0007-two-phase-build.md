# 0007 — Two-Phase Build: Fork PoC First, Then Native

**Status:** Accepted · sequences with [0003](./0003-native-swift-stack.md)

## Context

Two goals pulled in different directions: the user wants to **validate the proactive-coaching idea
fast** (timeline matters; "I'd like to try it first and then decide"), *and* wants a **clean,
secure, native** tool (small footprint, tight sandbox, separate-account build). A from-scratch
native Swift app is the right long-term answer but slow to a first working demo. Forking is fast
but inherits Electron and AGPL.

The fork evaluation ([fork-evaluation.md](../fork-evaluation.md)) found **Natively** already does
the two hardest things — both-sides macOS system audio and a *proactive* speak-up loop — and is
actively maintained and already multi-provider near our models.

## Decision

Resolve the tension with **time, not compromise** — two phases:

- **Phase 1 — Fast PoC by forking Natively.** Swap models to `gpt-5.5` / `gpt-realtime-2`, retarget
  Natively's existing proactive trigger to the LeetCode-coach case (silence/turn-end + timing),
  add the coach system prompt, ensure the overlay shows short ephemeral tips. Goal: a *working
  proactive coach to actually feel*, in roughly a day, to validate the experience. The full
  model-triggered `capture_screen` tool-loop is **deferred** to Phase 2 (Phase 1 leans on
  Natively's existing screen-understanding "decide" mode).

- **Phase 2 — The clean native Swift app** (governed by [0003](./0003-native-swift-stack.md)), built
  *only if Phase 1 validates the idea*, using Natively as a working reference for the Core Audio tap
  and proactive loop, and adding the proper `capture_screen` tool and the separate-account sandbox.

## Rationale

- Phase 1 answers "does proactive coaching feel right?" for ~a day of work instead of a week+.
- Phase 1 is a **throwaway spike**; the keeper is the Phase-2 native app. We don't over-invest in
  the fork.
- Honors the user's liking of Natively (build on it *and* learn from it), the timeline, and the
  native/secure end goal.

## Consequences

- Phase 1 temporarily accepts Electron + AGPL. Fine because it is **personal and not distributed**
  (AGPL's network/distribution obligations don't trigger); see [0002](./0002-personal-tool-first.md).
- Both phases build on the Mac in a separate restricted account (see [sandbox.md](../sandbox.md)).
- If Phase 1 *invalidates* the idea (proactive feels annoying, latency too high), we stop before
  paying for the native build — that's the point.
- Next: write the Phase 1 implementation plan.
