# wiki/AGENTS.md

Conventions for maintaining this wiki. Read before editing anything under `wiki/`.

The root `AGENTS.md` is *how to work in this repo*; this is *how to keep the docs healthy*. The wiki is
the design source of truth — what the system is, how it works, and why — so a fresh agent can pick the
project up mid-stream. Page list: [`index.md`](./index.md); current state: [`status.md`](./status.md).

## Principles

A **living knowledge base** — the project's current model of itself, not a history. Everything below
fights the two ways it rots:

- **Fossilization.** Dated / `v2` filenames, append-only specs, prose narrating what changed. Git holds
  the history; the wiki holds *what is true now*.
- **Fragmentation.** Many drifting micro-pages. One organized page beats a directory of stubs.

**Ownership.** The agent owns the bookkeeping — summarizing, cross-referencing, filing under the right
page, updating neighbors. The human owns judgment: what enters the wiki and what's worth documenting. If
the human ends up filing by hand, a convention below is underspecified — fix the convention, not the
symptom.

## Conventions

### 1. Edit in place. Never append dated or versioned copies.

Update the page directly; never create `architecture-2026-05.md` or `spec-v2.md`. Git is the history.

### 2. Read the full page before editing it.

A local edit that contradicts a distant section is the most common failure. Non-negotiable for
substantive edits.

### 3. Write in the present. Don't narrate refactors.

Describe the system as it is now; after a change a page should read as if the old concept never existed.
Delete on sight: "X was removed / replaced / deprecated"; "originally Y, now Z"; "Previously…", "No
longer…", "Used to be…"; `~~struck~~` items; obsolete non-goals. The *why it changed* lives in the pull
request and the git log; the *why it is this way* stays on the page
([Convention 8](#8-keep-rationale-beside-the-design-it-explains-there-is-no-decision-log)).

### 4. Reference source; don't paste code.

The wiki holds the *why* and the shape; the *what* — schemas, signatures, config values, constants —
lives in code: point to it by path/symbol (`see Config in src/config.ts`) instead of copying. A snippet
drifts the moment code changes; a pointer survives. Same for config facts (`package.json`, etc.). Prefer
text diagrams (Mermaid/PlantUML) over committed image binaries, which fossilize.

### 5. Cross-reference; don't duplicate.

Document each fact on one page; elsewhere, **link** to it. Two copies drift, and then the wiki lies.

### 6. Don't create empty pages.

If you can't write three meaningful sentences on a topic, don't make a page — an indexed `TODO` stub is
worse than a missing one. Exception: the scaffold pages (`index.md`, `status.md`) exist
for structure and stay even when near-empty — but a `status.md` left full of `<placeholders>` after work
starts is the stub this forbids.

### 7. Default to extending a page. Promote to a new page only when earned.

Start as a section in an existing page; don't pre-create `worker.md` / `wiki/transcription/`. Promote to its
own page only when one holds:

- **It's drowning its host** — past ~20% of the parent, or far deeper than its neighbors.
- **Three+ places link into it** — it's earned a stable target.
- **A genuinely new concept arrives** — a new subsystem / surface / role, not a refinement.

**Concrete-noun test:** can you finish "X is a ___" non-generically? "the sandbox is a worktree-isolated
process boundary" → yes; "good error handling matters" → no. **Cold start:** this governs *splitting*,
not the first page — create `architecture.md` as soon as you have three sentences. The wiki stays flat
until flat stops working; let taxonomy emerge. **Adding / renaming / removing a page → update
[`index.md`](./index.md) in the same edit** (a page not in the index is invisible); keep it a lightweight
map, not a second copy.

### 8. Keep rationale beside the design it explains. There is no decision log.

A design page states what is true now *and why*. When a choice is non-obvious, or an obvious
alternative was tried and rejected, say so in a sentence or two next to the fact it explains ("X, not
Y, because Z") — that is where a reader about to propose Y will be looking, and it is the only place
rationale persists in the wiki. Keep it to the choices a reader would re-litigate or a dead end they
would re-walk; skip what the code already makes obvious. The story of a *change* — what it was
before, what was learned, how it was validated — belongs in the pull request and the commit message,
not here. No running decision log and no ADR folder: a log appended per change fills with entries of
every weight, and its entries go stale while the pages they describe move on. When a choice is
reversed, rewrite the sentence on the design page; git holds the old one.

### 9. Run health checks, not only per-change updates.

The keep-in-sync checklist fires when you touch code; drift also accumulates silently between changes.
Periodically audit the whole wiki for the rot the write-time rules miss: contradictions between pages,
**orphan pages** (nothing links in — value is in the edges, not the nodes), one entity spelled two ways,
and claims the code no longer supports. A contradiction is information, not an error to paper over — it
means two pages, or a page and the code, disagree, and now you know where to look. An index you have to
bypass — reaching answers by scanning every page instead of [`index.md`](./index.md) plus a few — has
stopped reflecting the wiki and needs a pass.

## Keep-in-sync checklist

Run in the **same change (PR or commit)** as the code, never as a later cleanup. A change that alters
documented behavior without a doc update is incomplete; stale docs erode trust faster than they rebuild.

1. **[`status.md`](./status.md)** — move built things to "Built" with a file pointer; delete abandoned
   "Not yet built" items (if a reader might re-propose one, say why not on the design page); update
   phase + next action.
2. **Core page(s)** — create or update in place, present tense; touch every page whose meaning the change
   alters, not just the nearest one.
3. **Rationale** — a non-obvious choice or a rejected alternative goes on the design page beside the
   fact it explains ([Convention 8](#8-keep-rationale-beside-the-design-it-explains-there-is-no-decision-log));
   the change story goes in the pull request.
4. **[`index.md`](./index.md)** — update if a page was added, renamed, or removed.
5. **Links** — confirm every link and file pointer in touched pages still resolves.
6. **Duplicated facts** — code ↔ wiki, page ↔ page, code ↔ config: collapse to one source or link
   **within this same change**. Resolving drift is a requirement, not best-effort: no PR ships drift,
   and there is no parking lot for it — not the wiki, not the PR description, not a later cleanup.

A change isn't done until a fresh agent could reconstruct what's built and where to start, from
`index.md` + `status.md` + the touched pages.

## Not in the wiki

- **Brainstorms, plans, scratch drafts** — fold any design change and its rationale into the design
  page, discard the rest.
- **Tutorials / quickstarts / user guides** — those serve external users; they go in `README.md`.
- **Generated artifacts, logs, runtime output**, and **anything the code already states**
  ([Convention 4](#4-reference-source-dont-paste-code)).

One exception, by design: [`agents/`](./agents/) holds configuration the engineering skills read, in
their formats, not design documentation. Don't rewrite those files into wiki voice or fold them into a
design page. They are listed in [`index.md`](./index.md), so they aren't orphans.

## If you get stuck

If a page and the code disagree and nothing on the page explains the gap, that's drift: treat code as truth for
*what*, but flag it to a human rather than silently rewriting — the page may encode intent the code
drifted from.
