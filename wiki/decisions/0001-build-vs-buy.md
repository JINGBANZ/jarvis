# 0001 — Build Our Own vs. Use an Existing Tool

**Status:** Accepted

## Context

The goal was to find a proactive, always-on macOS assistant that speaks up unprompted based on
screen + audio. Before building anything, we surveyed and hands-on-tried the field (see
[landscape-survey.md](../landscape-survey.md)).

What we found:

- **Cluely** (the category leader) is hotkey-only and laggy (5–10s). It does not feel like a
  partner. Trying it is what made "proactive, unprompted" a hard requirement.
- **cheating-daddy**, the only open tool with auto-answer, didn't actually respond, is Gemini-only,
  and is effectively abandoned (founder absent on Discord, unanswered help requests).
- **Highlight AI** is waitlist-only — unavailable.
- **Pluely** and **Glass**, the open full-app options, are stale (5 and 8 months since last commit).
- **Hedy AI** does proactive coaching well but is closed-source and built for business meeting notes.
- **Omi** has a genuine proactive framework but is built around a hardware pendant.

## Decision

**Build our own.** No maintained, open-source tool does turnkey proactive speak-up from live audio
+ screen. The proactive options are hardware-bound, unproven, or closed; the available open tools
are reactive and stale.

Crucially, the gap is **small to fill**: the differentiator is a proactive trigger loop plus the
idea that *the model decides when to look at the screen*. Everything underneath (capture,
transcription, the brain) already exists as Apple frameworks and OpenAI APIs. We build a thin
harness, not an AI.

## Consequences

- We own the proactive behavior end-to-end — the thing nobody else does well.
- We avoid inheriting a stale or single-vendor codebase.
- We take on the work of wiring macOS capture + OpenAI ourselves, but only as glue.
- There is a noted market gap (cheating-daddy's frustrated users, Cluely's latency complaints);
  productizing later is left open but explicitly out of scope for v1 (see [0002](./0002-personal-tool-first.md)).
