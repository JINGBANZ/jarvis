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

Infer which stage the candidate is currently addressing from what they just said or what's
on screen, and keep your tip scoped to that stage — a caching tip is unhelpful while they
are still naming entities, and a repeated requirements question once requirements are
already named on the screen is stale.

During high-level architecture, and only when speak offers detail, make a useful hint visual: add
one small ```mermaid block to detail, alongside the short `lines` explaining what to draw or the key
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
