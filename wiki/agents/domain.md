# Domain Docs

Which documentation to read before exploring the codebase, and where a decision gets recorded once you
make one.

This repo keeps its design documentation in [`wiki/`](../index.md) — the source of truth for what the
system is, how it works, and why. There are no per-directory doc folders and no `CONTEXT-MAP.md`; it is
a single-context repo.

## Before exploring, read these

- **[`index.md`](../index.md)** — the navigation layer. Every page is listed there; a page not in the
  index doesn't exist. Read it before grepping the wiki.
- **[`status.md`](../status.md)** — what is actually built and what to do next. Read it before assuming
  a feature exists: the design pages describe intent, this one describes reality.
- **[`decisions.md`](../decisions.md)** — the running log, newest last. Check it for the area you're
  about to touch **before** proposing a direction. A rejected alternative is recorded there precisely so
  it doesn't get re-proposed.
- **The design page for the area you're touching** — `architecture.md` for the coaching loop,
  `sandbox.md` for the security and isolation model, `build-and-run.md` for toolchain and packaging,
  and the rest per `index.md`.

There is no `CONTEXT.md` glossary at the root yet. If one appears, read it too. Until then the wiki
carries the project's vocabulary. Don't flag its absence or propose creating one upfront —
`/domain-modeling` writes it when terms actually need resolving.

Operational facts — targets, commands, the Gate, the runtime safety boundaries — live in the root
[`AGENTS.md`](../../AGENTS.md), not here and not in the wiki.

## Recording a decision

Every load-bearing, non-obvious decision gets a dated entry in [`decisions.md`](../decisions.md) — what
you chose, why, what you rejected, newest last. That one running log is the whole mechanism; there is no
ADR folder, by design. [`../AGENTS.md`](../AGENTS.md) → Convention 8 holds the entry format and the
supersede rule.

## Editing the wiki

[`../AGENTS.md`](../AGENTS.md) governs every edit under `wiki/` — edit in place, read the full page
first, write in the present, reference source instead of pasting code, update `index.md` when adding a
page, and ship doc changes in the same PR as the code. Read it before touching any wiki file; it is not
the same file as the root `AGENTS.md`.

This directory is the exception: it holds configuration in the skills' formats, not design prose.

## Use the project's vocabulary

When your output names a domain concept — an issue title, a refactor proposal, a hypothesis, a test name
— spell it the way the wiki and the code spell it. One entity named two ways is exactly the drift a
health check (Convention 9) exists to catch.

If the concept you need has no name in the wiki, that's a signal: either you're inventing language the
project doesn't use (reconsider), or there's a real gap (note it for `/domain-modeling`).

## Flag conflicts rather than overriding them

If your output contradicts a recorded decision, say so explicitly:

> _Contradicts the 2026-07-18 entry on technical-interview context — but worth reopening because…_

If a page and the code disagree and no decision explains the gap, that's drift. Treat the code as truth
for *what*, but flag it to a human instead of silently rewriting the page — it may encode intent the
code drifted from.
