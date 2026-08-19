# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo keeps its design documentation in `wiki/`, not in scattered per-directory docs. The wiki is
the design source of truth — what the system is, how it works, and why.

## Before exploring, read these

- **`wiki/index.md`** — the navigation layer. Every wiki page is listed there; a page not in the index
  does not exist.
- **`wiki/status.md`** — where the project is right now and what to do next. Read this before assuming
  anything is built.
- **`wiki/decisions.md`** — the running decision log, newest last. Check it for the area you're about to
  touch before proposing a direction; a rejected alternative is recorded there for a reason.
- **`wiki/adr/`** — full architecture decision records for the decisions that earned one. The log entry
  in `decisions.md` links to its ADR; read the ADR when you need the options comparison, not just the
  outcome.
- **`CONTEXT.md`** at the repo root, if it exists — the domain glossary.

Single-context repo: one root `CONTEXT.md`, one `wiki/adr/`. There is no `CONTEXT-MAP.md` and no
per-directory ADR folders.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating
them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and
`/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT.md              ← domain glossary (created lazily)
├── wiki/
│   ├── index.md            ← navigation layer; update when adding a page
│   ├── status.md           ← current state
│   ├── decisions.md        ← the running decision log (every load-bearing decision)
│   ├── adr/
│   │   ├── 0001-<slug>.md  ← full records, for decisions that earned one
│   │   └── 0002-<slug>.md
│   └── <design pages>.md
└── Sources/
```

## Writing a decision

**Every** load-bearing, non-obvious decision gets a dated entry in `wiki/decisions.md`. Most decisions
stop there — the entry is the whole record.

Promote to a numbered ADR in `wiki/adr/` only when the entry can't carry it: the options were genuinely
weighed and the comparison itself is the value, the decision constrains work across several pages or
subsystems, or you expect it to be re-litigated and want the rejected options closed off in detail.
When you write one, the `decisions.md` entry stays and gains an `**ADR:**` link.

`wiki/AGENTS.md` → Convention 8 holds the entry format, the ADR template, numbering, and the
supersede rule. Read it before writing either.

## Read the wiki's rules before editing the wiki

`wiki/AGENTS.md` governs every edit under `wiki/`. It is not optional and it is not the same as the root
`AGENTS.md`. The rules that most often bite:

- **Edit in place** — never dated or `v2` copies (Convention 1).
- **Read the full page before editing it** (Convention 2).
- **Write in the present** — don't narrate refactors; the *why it changed* lives in `decisions.md`
  and `wiki/adr/` only (Convention 3).
- **Reference source, don't paste code** (Convention 4).
- **Adding, renaming, or removing a page means updating `index.md` in the same edit** (Convention 7).

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test
name), use the term as defined in `CONTEXT.md`, or as the wiki spells it. Don't drift to synonyms the
glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the
project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts a recorded decision, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_

A contradiction between a page and the code is information, not an error to paper over. Flag it to a
human rather than silently rewriting the page — it may encode intent the code drifted from.
