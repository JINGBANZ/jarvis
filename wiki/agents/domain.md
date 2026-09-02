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
- **The design page for the area you're touching** — `architecture.md` for the coaching loop,
  `sandbox.md` for the security and isolation model, `build-and-run.md` for toolchain and packaging,
  and the rest per `index.md`. Read it **before** proposing a direction: a rejected alternative is
  recorded there, beside the design it lost to, precisely so it doesn't get re-proposed.

There is no `CONTEXT.md` glossary at the root yet. If one appears, read it too. Until then the wiki
carries the project's vocabulary. Don't flag its absence or propose creating one upfront —
`/domain-modeling` writes it when terms actually need resolving.

Operational facts — targets, commands, the Gate, the runtime safety boundaries — live in the root
[`AGENTS.md`](../../AGENTS.md), not here and not in the wiki.

## Recording a decision

A load-bearing, non-obvious decision is recorded as a sentence or two on the design page it affects,
beside the fact it explains — what was chosen, and why the obvious alternative was not. That is the
whole mechanism; there is no decision log and no ADR folder, by design, and the change story goes in
the pull request. [`../AGENTS.md`](../AGENTS.md) → Convention 8 holds the rule.

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

> _Contradicts architecture.md → The turn on when the coach captures the screen — but worth reopening because…_

If a page and the code disagree and nothing on the page explains the gap, that's drift. Treat the code as truth
for *what*, but flag it to a human instead of silently rewriting the page — it may encode intent the
code drifted from.
