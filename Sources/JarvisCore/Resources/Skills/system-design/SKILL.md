---
name: system-design
description: Use when the question is a system design ("design a URL shortener", "how would you scale this"): the stages of a design round, what belongs in each, and when to add a diagram.
---
# System-design questions

When the current question is a system design, the discussion starts with clarifying questions, then moves through
functional requirements (what the system does, for whom), non-functional requirements (scale, latency,
availability, consistency, durability), core entities, API design, high-level architecture,
and finally a deep dive into whichever component the non-functional requirements make
hardest, ending on trade-offs — but the candidate may revisit an earlier stage at any point.
Name core entities before the API: an interface is easiest to define in terms of objects
that already have names, not vague fields.

At the start, suggest a focused question the candidate can ask the interviewer to clarify missing
scope, users, key actions, or constraints before listing requirements. For example: "Ask whether
links need to expire." Use the interviewer's answers to form functional and non-functional
requirements. Carry forward details already given instead of asking again. If an answer is still
missing, keep it open or label a proposed assumption for the candidate to confirm; do not present
it as an agreed requirement.

Write every hint in concise, plain English: one clear next step, with only the explanation needed
to act on it. Keep each line to one concrete idea. Prefer "store popular links in a cache so reads
are faster" to jargon or compressed technical shorthand. When speak offers detail, favor a short
bulleted list of the key points over paragraphs of prose: the panel is small, and an explanation
that needs scrolling arrives too late to help. Save full-paragraph walkthroughs for when the
candidate is genuinely stuck and asks you to explain, and even then cover only what unblocks them,
not a lecture.

Use the candidate's explicitly requested stage first. Otherwise follow the stage established by
the recent conversation, using the screen to fill gaps. A generic request for a hint continues
that stage. Visible notes from an earlier stage do not override a spoken transition. Keep your
tip scoped to that stage — a caching tip is unhelpful while they are still naming entities,
and a repeated requirements question once requirements are already named is stale.

When a stage transition warrants coaching, give a usable starting structure and one next move,
not just the stage name. Before suggesting the next stage, check that the current stage's purpose
is covered; point out its most consequential gap rather than restarting the checklist. Honor an
interviewer's requested deep dive or the candidate's explicit transition even with open questions.

For high-level design, start with a small connected sketch grounded in the requirements, naming
component responsibilities and one end-to-end flow. Check responsibility gaps before suggesting
what to draw: who validates the request, applies domain rules, writes durable state, and returns
success? A gateway described only as routing/authentication does not explain those jobs; name the
application or ingestion service that owns them before connecting to storage or a queue. If an
existing component or managed integration explicitly owns them, do not add a redundant service.
Endpoint spelling, payload fields, and identifier semantics belong in API design or a requested
deep dive.

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

For a deep dive, answer the latest available question at the named component first. Tie one
mechanism to the requirement: what operation happens, what state survives, how it resumes, and
what trade-off it makes. Distinguish the unit and boundary of each guarantee: a client request,
a queued record, a stored batch, and a business result can need different retry identities. Do not
substitute downstream deduplication for retry safety at the write being discussed. Keep one coherent
approach across hints; evaluate the candidate's proposal directly, and explain what changes and why
before recommending an alternative. A new proposal is not an agreed design.

For a throughput question, identify the expensive operation and where work is grouped or parallelized
in the current design. Explain why that reduces work per event before listing technologies. Name
who forms the batch, what one write stores, and when success is acknowledged; distinguish batching
at ingestion from batching in a downstream worker. Preserve the established durability boundary.
Include the relevant cost, such as waiting to fill a batch, and how size/time limits bound it.
Illustrative numbers explain the mechanism; they are not measured capacity or a universal best choice.

When the candidate says they cannot follow, misstates the mechanism, or repeats an unresolved
question, change the explanation immediately. Use one tiny concrete example in detail: one item or
batch, its identity, what is stored, and what a failure/retry does. Keep lines to the plain-language
answer and one next move; use short bullets for the example. Do not repeat abstract terms or add
more mechanisms, and do not wait for the Explain shortcut. Silence alone is not confusion.

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

When a warranted high-level architecture hint introduces or changes a component flow, include one
focused ```mermaid block in detail, including for an ordinary hint shortcut. This is a reason to
provide detail, not conditional on choosing prose detail first. Pair it with short lines explaining
what to draw and why. Begin with the smallest connected overview; later sketches focus on the
relevant branch, preserving the agreed components and boundaries. A text-only clarification need
not redraw an unchanged flow. The graph is a private suggested sketch, not a claim about what is
already drawn or an edit to the shared canvas. If detail is unavailable, name the boxes and flow
in lines. Keep requirements, entities, APIs, and deep-dive explanations text-only. Do not interrupt
productive progress or repeat an adequate hint merely to provide a diagram.

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
