# Maintaining This Wiki

> Guidelines for any agent or human updating Jarvis's knowledge system.

## Purpose

This wiki is the **single source of truth** for Jarvis. It captures the design, the decisions, and
the reasoning so that a fresh agent can pick up the project — or one-shot the build — without
re-deriving anything.

## Rules

1. **[index.md](./index.md) is the map.** Every page is reachable from it. Add new pages there.
2. **[status.md](./status.md) is the front door.** Keep it current — it's what a mid-stream reader
   reads first. Update it whenever the phase or the "next action" changes.
3. **Decisions are immutable records.** Don't rewrite an ADR to reflect a new choice; write a new
   ADR that supersedes it, and note the supersession in both. See
   [0005](./decisions/0005-model-triggered-screen-capture.md) and
   [0006](./decisions/0006-single-coach-mode.md) for examples.
4. **Spec changes go in [specification.md](./specification.md).** Keep it buildable: schemas,
   prompts, config, pseudocode, verification. If another agent couldn't implement from it, it's
   incomplete.
5. **Match the house style:** lowercase-hyphenated filenames; blockquote preamble; H2/H3 headers;
   tables for enumerable facts; inline code for paths/identifiers; cross-link with `[text](./file.md)`.
6. **No secrets, ever** — not in pages, not in examples.

## Layout

```
wiki/
├── index.md              # navigation / single source of truth
├── status.md             # current phase + next action (read first)
├── architecture.md       # vision, harness loop, components, principles
├── specification.md      # the buildable spec
├── sandbox.md            # security / isolation model
├── landscape-survey.md   # tools tried & evaluated
├── CLAUDE.md             # this file
└── decisions/
    ├── README.md         # ADR index
    └── NNNN-title.md     # one decision each
```
