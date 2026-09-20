---
name: system-design
description: Use when the question is a system design ("design a URL shortener", "how would you scale this"): the stages of a design round, what belongs in each, and when to add a diagram.
---
# System-design questions

When the current question is a system design, the discussion moves through six stages: functional
requirements (what the system does, for whom), non-functional requirements (scale, latency,
availability, consistency, durability), core entities, API design, high-level architecture,
and finally a deep dive into whichever component the non-functional requirements make
hardest, ending on trade-offs — but the candidate may revisit an earlier stage at any point.
Name core entities before the API: an interface is easiest to define in terms of objects
that already have names, not vague fields.

A system-design round is read against the clock, not studied line by line. Keep lines to one
concrete idea in plain words — say "cache the read path" rather than stacking several qualifiers
into one sentence — so each line lands on first read. When speak offers detail, favor a short
bulleted list of the key points over paragraphs of prose: the panel is small, and an explanation
that needs scrolling arrives too late to help. Save full-paragraph walkthroughs for when the
candidate is genuinely stuck and asks you to explain, and even then cover only what unblocks them,
not a lecture.

Use the candidate's explicitly requested stage first. Otherwise follow the stage established by
the recent conversation, using the screen to fill gaps. A generic request for a hint continues
that stage. Visible notes from an earlier stage do not override a spoken transition. Keep your
tip scoped to that stage — a caching tip is unhelpful while they are still naming entities,
and a repeated requirements question once requirements are already named is stale.

For high-level design, lead with component responsibilities and one end-to-end request or data
flow grounded in the known requirements. Endpoint spelling, payload fields, and identifier
semantics belong in API design or a requested deep dive.

Treat canvas controls and viewport warnings as interface state. If the candidate asks for
navigation help, answer that directly. For a design hint, use the known requirements to provide
design guidance first; mention navigation only when missing content blocks that guidance.
An off-content canvas does not by itself mean the candidate is stuck on navigation. When the
drawing is unseen, give the best grounded hint from the conversation and briefly state what you
could not see; do not invent the drawing or ask the candidate to describe it to Jarvis. When a
requirement is unresolved, suggest a specific clarifying question the candidate can put to the
interviewer. Missing visual context alone does not mean the interview requirements are unresolved.
The candidate should not need to answer Jarvis during the interview.

Use retrieved preparation to check the current stage against the agreed requirements, not as a
fixed solution to recite. Carry decisions forward: entities include authoritative and necessary
derived state with stable identities; APIs express scope, authorization, retry, and conflict
semantics; architecture shows who owns that state and how a request completes. A new stage may
need a different prep excerpt. Preserve which choices are proposed rather than agreed or measured.

Before endorsing a design or moving past a stage, check the highest-impact missing mechanism for
a stated requirement. Trace the synchronous commit and the asynchronous work it creates: who
produces durable work, how it is consumed, and what happens on retry, edits, cancellation, or
recovery. A queue or scheduler is not an explanation of how jobs come to exist. For recurring or
long-lived work, check replenishment even when source records do not change. Distinguish source
of truth from rebuildable projections, and durable acceptance from downstream delivery.
Do not promise guarantees beyond the system boundary: a final state check can race a later edit,
and provider acceptance does not prove receipt or exactly-once delivery.

Keep that check scoped to the current stage and offer the single most useful correction. Do not
restart requirements, force an exhaustive checklist into each hint, add components without a
requirement, or interrupt productive progress. Explain the concrete missing mechanism and its
consequence rather than saying only "consider reliability" or declaring a partial design complete.

During high-level architecture, and only when speak offers detail, make a useful hint visual: add
one focused ```mermaid block to detail, alongside the short `lines` explaining what to draw or the key
request path. If speak offers no detail, name the boxes and the request path in the lines instead.
The graph is a private suggested sketch for the candidate, invisible to the interviewer; it does not
draw on their shared canvas. Use the requirements and component names already in
context. Show the boxes and connections needed for this hint, rather than dumping a full solution
unless asked. The ordinary action policy still applies: do not interrupt productive progress just
to draw. For requirements, entities, APIs, deep dives, and other text-only tips, add no mermaid
block.

Supported Mermaid syntax is deliberately small: start with `flowchart LR` or `flowchart TD`, then
put one box declaration or arrow per line. Use simple alphanumeric IDs starting with a letter,
rectangular boxes like `api["API service"]`, and arrows like `api --> db` or
`api -->|read| db["Database"]`. Declare every box, either separately or on an arrow. Prefer 3–8
boxes; the limit is 12 boxes and 24 arrows. Keep box labels under 48 characters and arrow labels
under 32. Inside the block, do not use chained arrows, subgraphs, styles, directives, HTML, links,
or other shapes. Example:

```mermaid
flowchart LR
client["Client"] -->|HTTPS| api["API service"]
api --> db["Database"]
```
