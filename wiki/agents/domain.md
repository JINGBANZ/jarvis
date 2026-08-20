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
- **[`adr/`](../adr/README.md)** — full records for the decisions that earned one. The `decisions.md`
  entry links to its ADR; read the ADR when you need the options comparison rather than the outcome.
- **The design page for the area you're touching** — `architecture.md` for the coaching loop,
  `sandbox.md` for the security and isolation model, `build-and-run.md` for toolchain and packaging,
  and the rest per `index.md`.

There is no `CONTEXT.md` glossary at the root yet. If one appears, read it too. Until then the wiki
carries the project's vocabulary. Don't flag its absence or propose creating one upfront —
`/domain-modeling` writes it when terms actually need resolving.

Operational facts — targets, commands, the Gate, the runtime safety boundaries — live in the root
[`AGENTS.md`](../../AGENTS.md), not here and not in the wiki.

## Recording a decision

**Every** load-bearing, non-obvious decision gets a dated entry in [`decisions.md`](../decisions.md).
Most stop there; the four-line entry is the whole record, and the log stays readable because of it.

Promote to a numbered ADR in [`adr/`](../adr/README.md) only when the entry can't carry it: the options
were genuinely weighed and the comparison is the value, the decision constrains several subsystems, or
you expect it re-litigated and want the rejected options closed off in detail. A promoted decision keeps
its log entry and gains an `ADR:` link — entries never move out of the log.

[`../AGENTS.md`](../AGENTS.md) → Convention 8 holds the entry format, the ADR template, numbering, and
the supersede rule. Read it before writing either.

## Editing the wiki

[`../AGENTS.md`](../AGENTS.md) governs every edit under `wiki/`. It is not the root `AGENTS.md`, and it
is not optional. The rules that most often catch agents out:

- **Edit in place** — never a dated or `v2` copy (Convention 1).
- **Read the full page before editing it** — a local edit contradicting a distant section is the most
  common failure (Convention 2).
- **Write in the present** — don't narrate refactors. After a change the page should read as if the old
  concept never existed; the *why it changed* lives only in `decisions.md` and `adr/` (Convention 3).
- **Reference source, don't paste code** — signatures, config values, and constants drift the moment
  they're copied; point at the path or symbol (Convention 4).
- **Adding, renaming, or removing a page means updating `index.md` in the same edit** (Convention 7).
- **Doc updates ship in the same PR as the code**, never as a later cleanup (keep-in-sync checklist).

This directory is the exception: it holds configuration in the skills' formats, not design prose, and is
exempt from the page conventions above.

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
