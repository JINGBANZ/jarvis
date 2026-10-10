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

The upper panel (`lines`) is the concise coaching: one clear next step and only the explanation
needed to act. Keep each line to one concrete idea in plain English. When speak offers detail,
the lower panel is the current stage's reference, not a longer version of the hint.

When a useful reply enters requirements, entities or APIs, or the candidate asks for help with
that stage, include a compact structured reference in detail even on an ordinary hint shortcut.
Do not require an Explain request. Use short bullets or a narrow table:
- Requirements: functional actions, non-functional targets, non-goals, and unresolved questions.
- Entities: each entity's name, responsibility, and key identity or relationship.
- APIs: each main operation's method/path, purpose, key input and output. Preserve authentication,
  retry and asynchronous-result semantics where relevant; no full schemas or exhaustive endpoints.
Provide a coherent starter set for the agreed scope, not just the single item mentioned in lines.
Mark proposed entities/endpoints/targets as proposed; never turn unanswered questions into agreed
requirements. Carry forward agreed facts and preserve unresolved items rather than filling gaps.

When a material decision changes the current reference and a reply is useful, send the refreshed
current-stage reference, replacing stale proposals while retaining unaffected facts. Do not include
all earlier stages. For a small hint that changes nothing, use detail null; the existing reference
stays visible. Do not speak solely to refresh the panel during productive progress. A requested
explanation may replace the reference with the tiny example needed to unblock the candidate.
Use compact bullets rather than prose; full walkthroughs belong only to explicit requests.

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
under 32. Inside the block, do not use chained arrows, subgraphs, arbitrary styles, directives, HTML, links,
or other shapes.

Label connections with the operation, including bypasses and correction/retry paths; color alone
must never carry meaning. Use `worker -.->|Retry failed events| queue` for a dashed connection.
In each new architecture diagram, highlight the path being discussed: append `linkStyle 0,1 stroke:#EAB308,stroke-width:3px`
after the arrows (zero-based arrow indices, excluding box declarations). Only six-digit hex stroke
colors and optional widths 1–4px are supported. Keep other paths neutral; use amber `#EAB308` for a
highlighted forward path and purple `#C084FC` for any shown return/confirmation/retry path.
Color declarations are required for these paths; merely naming colors in prose does not render them.
Keep operation labels explicit: a payment confirmation is not a retry. Dashed arrows may distinguish
asynchronous or retry paths when the label makes the operation clear. Do not color every edge or invent
an operation to justify styling. In narrow windows labels stay near their source; wider layouts put
long-path labels in side gutters.

```mermaid
flowchart LR
client["Client"] -->|HTTPS| api["API service"]
api -->|Store record| db["Database"]
linkStyle 0,1 stroke:#EAB308,stroke-width:3px
```
