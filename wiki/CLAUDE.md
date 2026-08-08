# wiki/CLAUDE.md

Conventions for maintaining this wiki. Read before editing anything under `wiki/`.

The root [`CLAUDE.md`](../CLAUDE.md) is *how to work in this repo*; this is *how to keep the docs
healthy*. The wiki is Jarvis's design source of truth — what the system is, how it works, and why — so
a fresh agent can pick the project up mid-stream or one-shot the build without re-deriving anything.
Page list: [`index.md`](./index.md); current state: [`status.md`](./status.md).

## Principles

A **living knowledge base** — the project's current model of itself, not a history. Everything below
fights the two ways it rots:

- **Fossilization.** Dated / `v2` filenames, append-only specs, prose narrating what changed. Git holds
  the history; the wiki holds *what is true now*.
- **Fragmentation.** Many drifting micro-pages. One organized page beats a directory of stubs.

## Conventions

### 1. Edit in place. Never append dated or versioned copies.

Update the page directly; never create `architecture-2026-05.md` or `spec-v2.md`. Git is the history.

### 2. Read the full page before editing it.

A local edit that contradicts a distant section is the most common failure. Non-negotiable for
substantive edits.

### 3. Write in the present. Don't narrate refactors.

Describe the system as it is now; after a change a page should read as if the old concept never existed.
Delete on sight: "X was removed / replaced / deprecated"; "originally Y, now Z"; "Previously…", "No
longer…", "Used to be…"; `~~struck~~` items; obsolete non-goals. The *why it changed* lives only in the
git log and the decision log ([Convention 8](#8-log-load-bearing-decisions-in-one-place-dont-accumulate-decision-files)).

### 4. Reference source; don't paste code.

The wiki holds the *why* and the shape; the *what* — schemas, prompts, signatures, config values,
constants — lives in code (`ToolDefs.swift`, `Config.swift`, `CoachDriver.swift`, …): point to it by
path/symbol (`see Config in Sources/JarvisCore/Config/Config.swift`) instead of copying. A snippet drifts
the moment code changes; a pointer survives. Prefer text diagrams (Mermaid/PlantUML) over committed
image binaries, which fossilize.

### 5. Cross-reference; don't duplicate. Match the house style.

Document each fact on one page; elsewhere, **link** to it. Two copies drift, and then the wiki lies.
House style: lowercase-hyphenated filenames; a blockquote preamble; H2/H3 headers; tables for enumerable
facts; inline code for paths/identifiers; cross-link with `[text](./file.md)`.

### 6. Don't create empty pages.

If you can't write three meaningful sentences on a topic, don't make a page — an indexed `TODO` stub is
worse than a missing one. Exception: the scaffold pages (`index.md`, `status.md`, `decisions.md`) exist
for structure and stay even when near-empty — but a `status.md` left full of `<placeholders>` after work
starts is the stub this forbids.

### 7. Default to extending a page. Promote to a new page only when earned.

Start as a section in an existing page; don't pre-create stub pages. Promote to its own page only when one
holds:

- **It's drowning its host** — past ~20% of the parent, or far deeper than its neighbors.
- **Three+ places link into it** — it's earned a stable target.
- **A genuinely new concept arrives** — a new subsystem / surface / role, not a refinement.

**Concrete-noun test:** can you finish "X is a ___" non-generically? "the overlay is a capture-invisible
`NSPanel`" → yes; "good error handling matters" → no. **Cold start:** this governs *splitting*, not the
first page — create `architecture.md` as soon as you have three sentences. The wiki stays flat until flat
stops working; let taxonomy emerge. **Adding / renaming / removing a page → update [`index.md`](./index.md) in the same
edit** (a page not in the index is invisible); keep it a lightweight map, not a second copy.

### 8. Log load-bearing decisions in one place. Don't accumulate decision files.

Decisions go in one running log, [`decisions.md`](./decisions.md): one dated entry each (what you chose,
why, what you rejected, where the detail lives), newest last. No numbered ADR folder — that's its own
sync-and-cross-link burden, and at this stage that ceremony isn't worth it. It's a dedicated page, not
part of [`status.md`](./status.md): status is volatile current-state, the log is durable. Log only
genuinely **load-bearing, non-obvious** choices — ones a reader would re-litigate or a dead end they'd
re-walk; skip what the code or PR already explains. This is the **one** place past rationale persists, so
[Convention 3](#3-write-in-the-present-dont-narrate-refactors) does *not* apply to it. **Supersede, don't
rewrite:** when a later decision reverses an earlier one, leave it and append `**Superseded by:** <entry>`
— the lifecycle a numbered ADR would carry, in one line.

## Keep-in-sync checklist

Run in the **same change (PR or commit)** as the code, never as a later cleanup. A change that alters
documented behavior without a doc update is incomplete; stale docs erode trust faster than they rebuild.

1. **[`status.md`](./status.md)** — move built things to "Built" with a file pointer; delete abandoned
   "Not yet built" items (log why in `decisions.md` if load-bearing); update phase + next action.
2. **Core page(s)** — create or update in place, present tense.
3. **[`decisions.md`](./decisions.md)** — log any load-bearing decision.
4. **[`index.md`](./index.md)** — update if a page was added, renamed, or removed.
5. **Links** — confirm every link and file pointer in touched pages still resolves.
6. **Duplicated facts** — code ↔ wiki, page ↔ page, code ↔ config: collapse to one source or link
   **within this same change**. Don't ship drift; if a mismatch genuinely can't be resolved here, call it
   out explicitly in the PR description rather than parking it in the wiki.

A change isn't done until a fresh agent could reconstruct what's built and where to start, from
`index.md` + `status.md` + the touched pages.

## Not in the wiki

- **Brainstorms, plans, scratch drafts** — extract any real decision to `decisions.md`, discard the rest.
  Brainstorm/plan docs are fine to write *while building*; they just don't live in the wiki afterward.
- **Tutorials / quickstarts / user guides** — those serve external users; they go in `README.md`.
- **Generated artifacts, logs, runtime output**, and **anything the code already states**
  ([Convention 4](#4-reference-source-dont-paste-code)).
- **No secrets, ever** — not in pages, not in examples.

## If you get stuck

If a page and the code disagree and no decision explains the gap, that's drift: treat code as truth for
*what*, but flag it to a human rather than silently rewriting — the page may encode intent the code
drifted from.
