# 0006 — Single LeetCode-Coach Mode (No Tiers)

**Status:** Accepted · supersedes the earlier "tiered sensitivity dial (quiet/normal/chatty)"

## Context

An earlier design had a configurable sensitivity dial with three trigger tiers (direct-address,
question-detection, full-situational) so Jarvis could serve many situations. That is more UI and
more behavior-tuning than an MVP needs, and it spreads effort across use cases none of which would
be polished.

## Decision

**Ship one mode: LeetCode Coach.** Jarvis watches you solve a LeetCode problem, hears you think
aloud, looks at the screen when it needs to, and offers short tips that guide you toward the
solution without handing it over. No mode selector, no tiers.

The proactive trigger is simply: on each conversational turn (or after a silence), let the model
decide whether to coach — gated only by the safety guardrails (cooldown, rate cap, mute).

## Rationale

- One excellent mode beats three mediocre ones for an MVP.
- Removes the mode-selector UI and the per-tier tuning work — less code, faster build.
- The coach use case is concrete and easy to verify (planted problem + planted question).

## Consequences

- The "intelligence" reduces to one well-crafted system prompt (see
  [specification.md](../specification.md#4-coach-system-prompt-mvp)).
- Additional modes are a deliberate future expansion, not part of v1.
- The trigger model is intentionally simple; no question-classifier or wake-word engine in v1.
