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
3. **No formal ADRs at this stage.** Be conservative about decision ceremony. Record decisions as a
   compact one-line entry in [status.md](./status.md#key-decisions); put the *rationale* in the
   relevant design page (architecture / fork-evaluation / sandbox). Reserve heavier decision records
   for big product decisions, once there's a product.
4. **Don't document what the code already states.** Schemas, prompts, config values, and pseudocode
   live in `Sources/` (`ToolDefs.swift`, `Config.swift`, `CoachDriver.swift`, …) — do **not** copy
   them into the wiki, or they drift. The wiki holds the *why* (rationale, tradeoffs, decisions); for
   the *what*, link to the source file. New design rationale goes in
   [architecture.md](./architecture.md).
5. **Match the house style:** lowercase-hyphenated filenames; blockquote preamble; H2/H3 headers;
   tables for enumerable facts; inline code for paths/identifiers; cross-link with `[text](./file.md)`.
6. **No secrets, ever** — not in pages, not in examples.
7. **The wiki holds final state, not intermediate scaffolding.** Persist the design and the
   decisions; do **not** keep build-time artifacts like step-by-step implementation plans once the
   work has shipped — fold anything still true into the relevant design page and delete the plan.
   (Brainstorm/plan docs are fine to write *while building*; they just don't live in the wiki
   afterward.)

## Layout

```
wiki/
├── index.md                 # navigation / single source of truth
├── status.md                # current phase, key-decisions log, next action (read first)
├── architecture.md          # vision, harness loop, components, models/APIs, resilience, safety
├── build-and-run.md         # operational: toolchain, signing/TCC, running, dev-mode viewer
├── sandbox.md               # security / isolation model
├── overlay-invisibility.md  # hiding the overlay from screen capture (`sharingType = .none`)
├── landscape-survey.md      # tools tried & evaluated
├── fork-evaluation.md       # code-level eval of fork bases
└── CLAUDE.md                # this file
```
