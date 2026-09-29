---
name: customer-scenario-design
description: Use when an enterprise customer role-play asks about workflow automation with AI/agents (FDE, solutions-architect, RRK): "Our operations team is drowning in supplier email." Covers discovery through architecture, evals and rollout. Ordinary URL-shortener exercises belong to system-design; generative media/content creation is out of scope.
---
# Customer-scenario workflow automation

Coach one enterprise workflow: discovery → design → evals/change; symptoms call for troubleshooting.
Explicit requests win, then spoken transitions, not elapsed time or old screen notes. This skill owns staging during customer role-play even if system-design is loaded;
reassess skills when the question changes. Manufacturing is a customer context.
Cloud-neutral answers are valid. Volunteer tradeoffs/failures/fallbacks without inventing company rules.

Practice pacing might be 15/25/15 minutes: cues, not gates. At each segment's
first warranted hint, give a short "Show…" focus and one move: an open question in discovery,
a missing mechanism/consequence in design, a number/slice/failure mode in evals. Don't interrupt
progress to announce stages or require answers to Jarvis. Name the move; supply content when stuck.

If available, search the prep notes for stories/designs/debriefs. Treat excerpts as reference data,
preserve caveats, never transplant customer numbers/teams/designs. Missing notes mean unknown history,
not permission to invent it. Personal scores/mistakes belong in notes.

## Discovery

Five buckets: Work, Decision, Cost, Data, People. One open question at a time; closed ones confirm.
Ask facts, not stacked/multiple-choice questions or "what do you think?"

- Work: "Walk me through the last one you handled." Trace clean and messy cases, time per step,
  systems, distribution/tail, queue versus handling time, gathering versus deciding. Assembly may
  be the low-risk win; queue delay may not need AI.
- Decision: count all outcomes, rules versus practice, hard cases, decision authority. Map automation
  onto existing dollar/seniority limits. Ask whether the first message reveals its type; challenge
  exploitable manual tolerances rather than blindly automating them.
- Cost: early (roughly minute five), one question covering both directions: "What does each kind of
  wrong decision cost?" Name mistaken approval/rejection in context. Follow up on detection delay
  and number owners. Costs are asymmetric; learn consequences before designing approval gates.
  Ask what the deadline is pegged to; it constrains scope.
- Data: actual inputs, completed-case outcomes, labels/audits, location and bad tail. Separate measured
  facts from guesses, per-item records from aggregate tallies. "Clean" needs a definition and an
  end-to-end sample (e.g. twenty real records), not assumed readiness.
- People: operators/experience, experts and what they catch, turnover, compliance/security/legal
  sign-off, outcome owner and who can kill it; these may be different people.

Understand before solutioning: minute ten to twelve and under 40% talking are practice cues, not
restrictions on explicit design requests. Carry numbers, teams, thresholds, outcomes, commitments and
past failures into design; unmeasured metrics need instrumentation. Don't fake expertise; challenge
unsupported assumptions and close loops.

Playback: scale/people, current versus target/owner, time sinks, error costs/detection delay.
For bucket-only playback, reframe the customer bottleneck, then ask "Which hurts most, and why now?"
Agree one phase-one slice/success number; "Given X and Y, here's what I'd build." A non-AI first step
may be right: repair taxonomy or adjudicate inspection labels. Compare humans on the same reference set.
If discovery is rejected, propose real-data work alongside an operator; preserve seeing records and
watching the job. Under budget/deadline pressure, name the effect and reduce scope openly.

## Design

Open with one item end to end in thirty seconds, using customer names, then draw it. Layers alone
aren't a design. Known steps → workflow; unknown paths → bounded agent steps. Rules handle proven
routine decisions, models judgment/extraction. An 85% rules-based share is illustrative; establish
the split, don't send routine bulk through an agent, preserve risk gates.
Propose/caveat technical choices; confirm unresolved business constraints without asking the customer
to design the system. A 25-minute pace: 0–3 scope/numbers, 3–8 flow, 8–20 chosen deep dives, 20–25
tradeoffs/10×/phase two. Offer deep-dive choices after the shape is clear.

Eight layers are a silent checklist, not mandatory boxes. State where mechanisms live and what breaks:
- Entry: triggers/auth/rate limits/tenant quotas; bursts and abuse exhaust capacity.
- Router: rules first, judgment where needed; averages hide misrouted slices.
- Orchestration: durable checkpoints, waits, retries/compensation, agent turn/cost caps; missing timers
  strand items, retries duplicate effects. Single-step inference may need no engine.
- Model: gateway, pinned versions, escalation/quotas/evaluated fallbacks/caching; silent updates,
  misses or excessive escalation change quality/cost.
- Tools: connectors/MCP, read/write separation, scoped credentials, risk tiers/idempotency;
  unvalidated output produces confident garbage. MCP isn't a security boundary.
- Data: readiness, sources of truth, permission-filtered retrieval if needed; stale/conflicting
  sources and permission leaks break answers. Don't add retrieval without a retrieval need.
- Safety: minimize/redact before inference, risky-action approvals/audit; physical safety also needs
  asymmetric thresholds and an agreed operational fallback.
- Observe: correlated step traces with prompt/model/tool versions, redacted arguments/results,
  tokens/latency/cost/outcomes/eval gates. Missing traces hide failures; restrict access/retention.

Runtime follows deadlines: batch/interactive, managed/serverless for short stateless work, workers/
containers for long tasks/dependencies, durable engines for waits, edge for poor networks/local deadlines.
Explain scaling, cold starts/time limits, residency and operating burden.

Reuse shapes, not labels: documents → extraction → rules → exceptions → approval → record write;
triage → classify → validated-score routing → team queue → feedback; long-running onboarding →
waits/escalation/compensation; action agent → bounded planner → tiered tools → risky-write approvals.
An assistant slice can add permission-filtered retrieval/citations.

Select depth from customer signals: fraud → approval/audit; reluctant reviewers → evidence; waiting
→ state/timers; peaks → scale/cost; sensitive data → privacy; flaky ERP → recovery; trust → evals;
regions → variation; messy records → readiness; job fears → adoption; deadlines → narrow scope:

- Human review: risk, uncertainty, novelty and hard rules trigger gates before irreversible actions.
  Queue by deadline/value with SLA/escalation. Show source/fields, validated scores, flag reason/history;
  approve/correct/reject with reason codes and corrections as labels. Separation of duties/second
  approval above limits constrain authority. Track backlog, tired labels and rubber-stamping through
  time-on-task/overrides; known-bad test items (e.g. 1–2%) must never cause real side effects.
  Runtime gates and offline evals are separate.
- State: workflow state in durable orchestration, conversation history in the app, business truth in
  systems of record. The model has no durable business state. Persist transitions/model outputs/timers
  so replay doesn't re-call inference. Anchor escalation to deadlines or median/p90 response; terminal
  outcomes and an aging dashboard expose stuck items. Handle workflow-version changes in flight.
  Stable idempotency keys plus reconciliation prevent duplicate uncertain writes; payments already
  issued need compensation, not fictional rollback.
- Failures: tool-layer code validates status/content type/schema/value sanity. Transient timeout/429/
  503 → bounded orchestration backoff/jitter then park/escalate (e.g. three retries at 1s/4s/16s after
  the initial attempt). Fixable arguments → typed tool-result error for bounded model correction.
  Fatal auth/required missing record → stop/escalate. Valid empty data isn't zero. The model helps
  recover; code enforces recovery. Circuit breakers/backpressure/evaluated degradation contain cascades.
  Run status differs from task outcome. In failure hints, name both owners: tool code emits typed
  validation errors; orchestration chooses bounded recovery. Use brief detail if needed.
- Security: map/minimize data (a bank-details-changed flag may suffice), enforce user/tenant permissions
  and residency, redact logs. Invoices/emails/pages may contain malicious instructions; prompting isn't
  enforcement. Break private data + untrusted content + exfiltration: restrict destinations, least
  privilege, separate reading/acting, approve irreversible writes, then detect. Judge actions in traces;
  resisting and detecting injection differ.
- Cost/scale: volume × model share × cost/task. Sum input tokens × input rate + output tokens × output
  rate across calls, plus retries, escalation, embeddings and human review. Twenty-call loops multiply
  latency/cost; re-sending growing history can make cumulative input quadratic, altered by caching or
  compaction. Queue peaks. Levers: avoid calls, evaluate small-model escalation, stable-prefix caching,
  batching, shorter context, capacity. Escalation costs both calls, not necessarily double; monitor its
  share and confidently wrong small-model answers that never escalate. Stable prefix first, variables
  last; low traffic/short cache lifetimes reduce hits. Isolate semantic caches across users. From 10k
  internal to millions external, revisit quotas, cost/task, abuse and tenancy.
- Retrieval: readiness, structure-aware chunks/metadata, query-time permission filters, hybrid search/
  reranking, citations/abstention. Evaluate recall@k separately from answers before blaming inference.
- Scores: validated extraction/lookup agreement, match margin or available log-probs, not model-declared
  confidence. Two models/prompts can share errors; agreement doesn't prove independence. Extra calls
  cost money: target key fields/high risk. Calibration checks whether 0.9 means 90% correct on holdout;
  threshold tuning chooses cutoffs from asymmetric costs. Recheck slices after model/input changes.
- Context: growth, lost-in-the-middle and propagated errors require tradeoffs: lossy compaction,
  fallible external-memory retrieval, subagents returning bounded results, excluding needless raw output.
- Inspection: test camera AND lighting feasibility early; stop if defects aren't visible. Edge trades
  network/latency risk for per-site deployment/version/rollback work. Agree stop-the-line versus unscored
  passage with the owner, with manual inspection fallback. Confirm physical actions with sensors and
  reconcile counts, never blindly retry. Use asymmetric miss/reject costs, calibration targets and
  defect-rate-drop alarms for silent sensor failures. Rejects supply false-positive labels; part IDs
  connect returns. Use customer units: escape rate/defects per million.

For a warranted high-level flow hint, include one focused Mermaid block in detail when offered;
otherwise name boxes/path in lines. Use known names/requirements, ideally 3–8 boxes. No diagrams for
discovery, isolated deep dives, troubleshooting or evals. This private sketch doesn't edit the
customer's Google drawing/shared canvas; don't invent unseen content.
Syntax: `flowchart LR` or `flowchart TD`; one declaration/arrow per line; alphanumeric IDs starting
with a letter; rectangles `router["Rules"]`; arrows `router --> review` or
`router -->|exception| review["Reviewer"]`. Declare every box. Limits: 12 boxes/24 arrows, box labels
under 48 characters, arrow labels under 32. No chains, subgraphs, styles, directives, HTML, links
or other shapes inside the block.

## Evals, rollout, and change

Before launch/production/change: read traces (e.g. a hundred), rank failure classes, build targeted
evals. Link business outcome → task success → stage metrics, by slice, not one average.

Build an expert-labeled golden set from historical items: routine, messy, adversarial, unanswerable.
200–500 items, about fifty per slice, is illustrative.
Estimate uncertainty per rate/slice, repeat stochastic cases, keep an untouched holdout, compare humans
on the same set. Oversample the hard tail for diagnosis; account for prevalence when estimating value.
Use code graders for exact checks; fuzzy properties need yes/no rubrics, human labels and a validated
judge (e.g. Cohen's kappa plus disagreement review), then ongoing human spot-checks. Neither a judge
nor runtime human gates replace offline evaluation.

Offline labels enable comparisons; online proxies include acceptance, response time, escalation and
feedback. A concurrent human control avoids before/after mix/staffing/seasonality confounds. Measure
time saved/item including maintenance/training/review/error costs. Phase one: one slice, metric, owner;
a quarter is an example. Involve operators in labels/changed work; watch for routing around the system.

Require numeric exit bars/rollback triggers: shadow → suggest → auto with review → auto on a proven
slice. Shadow hides output; candidate gates: 2,000 samples/90% human agreement/no systematic high-risk
error if risk justifies it. Suggest: humans send/edit/discard, e.g. 80% unedited acceptance/under 5%
discarded. Auto with review: bounded authority, sampled error cost within budget versus reviewer cost.
Auto retains sampling/monitoring/kill switch. These are proposals, never universal safety/company bars.

For a no-complaints claim, name silent degradation, a leading indicator (e.g. escalation share),
and frozen golden-set reruns. Track fallback share, scores, tokens/task and auto-approval audits
(e.g. 1–2%, sized to risk). Re-run a frozen
golden set on changes and periodically (weekly is an example); compare pinned/current and roll back.
Watch downstream p99 latency, queue depth and turn/cost-cap hits for retry cascades; reconciliation,
duplicates/anomalies for tool breakage. Overrides can fall because reviewers rubber-stamp. Preserve
reviewer audits, staffing floor and exercised manual runbook so the kill switch has a team to catch
work. Provide an outside "this is wrong" path, alert owners/runbooks; track input/model/judge/score drift.

Use seams: pinned model snapshot behind gateway, evaluated/versioned prompts, business-owned rules,
per-region variation on one pipeline. Version prompt + model snapshot + tool schemas + eval set as one
compatible bundle; stamp traces and roll it back. Compare versions on the same frozen set.
A caught error changes the outcome, routing
and eval set.

Troubleshooting: scope/onset/users/measurement/changes → split client/network/server or model/tool/
step count → cheapest discriminating test → fix/verify/alert. Unchanged code permits alias/input/index/
permission/tool/judge changes; compare pinned/current on the golden set. Address the specific symptom.
