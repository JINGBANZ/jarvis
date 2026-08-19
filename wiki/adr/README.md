# Architecture Decision Records

Full records for the decisions that earned one. The chronological index of **every** load-bearing
decision is [`../decisions.md`](../decisions.md) — start there. An ADR is the depth behind one of its
entries, never a replacement for it.

When to write one, and the numbering and supersede rules, live in [`../AGENTS.md`](../AGENTS.md) →
Convention 8. Read it first; most decisions belong in the log alone.

## Index

_No ADRs yet._

<!-- Add each ADR here as: - **[ADR-NNNN](./NNNN-slug.md)** — one-line summary. _(Status)_ -->

## Template

```markdown
# ADR-NNNN — <decision, as a statement>

**Status:** Accepted
**Date:** YYYY-MM-DD

## Context

The forces in play: what problem, what constraints, what was already true. Present tense, no narration
of how the discussion went.

## Decision

What we chose, stated plainly. Point at the code and design pages that carry it out (`see CoachDriver in
Sources/JarvisCore/Coach/CoachDriver.swift`, [`../architecture.md`](../architecture.md)) rather than
restating them.

## Alternatives considered

The comparison this ADR exists for. One heading or row per option, each with why it lost. Enough detail
to close the argument the next time it opens.

## Consequences

What this commits us to, what it rules out, and what now needs watching.
```

Set `**Status:** Superseded by [ADR-NNNN](./NNNN-slug.md)` when a later decision reverses this one, and
add `**Supersedes:** [ADR-NNNN](./NNNN-slug.md)` to the new record. Never delete or rewrite a superseded
ADR — the reversed decision is the part you don't want to lose.
