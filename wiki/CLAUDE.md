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
   relevant design page (architecture / specification / fork-evaluation / sandbox). Reserve heavier
   decision records for big product decisions, once there's a product.
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
├── status.md             # current phase, key-decisions log, next action (read first)
├── architecture.md       # vision, harness loop, components, principles
├── specification.md      # the buildable spec
├── sandbox.md            # security / isolation model
├── landscape-survey.md   # tools tried & evaluated
├── fork-evaluation.md    # code-level eval of fork bases
├── plan-phase1-poc.md    # Phase 1 implementation plan (fork Natively)
└── CLAUDE.md             # this file
```
(Generated `*.html` review files and `build_html.py` also live here but are gitignored / tooling.)
