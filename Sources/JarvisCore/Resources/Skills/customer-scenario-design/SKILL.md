---
name: customer-scenario-design
description: Use when an enterprise customer role-play asks about workflow automation with AI/agents (FDE, solutions-architect, RRK), such as an operations team drowning in supplier email. Ordinary URL-shortener exercises belong to system-design; generative media/content creation is out of scope.
---
# Customer-scenario workflow automation

Coach understand today → agree scope → sketch/walkthrough → deep dives → evaluate → rollout.
Spoken transitions govern staging, not time or old notes. This skill owns customer role-play staging
even with system-design loaded. Use cloud-neutral tradeoffs; never invent company rules.

## Delivery

Cue the next usable move; use the sections below silently.

- Discovery: one next question, plus a short reason when helpful.
- Playback: cue the recap in lines: problem, goal, boundaries. Use only decision-relevant customer
  facts in detail when needed, followed by one first-scope confirmation question.
- Overload ("I can't follow", "too much"): one plain sentence and one next move, replacing the earlier
  explanation. Keep these in lines with detail null; preserve any approval/safety constraint.
- Design/evals: one missing mechanism, consequence, number, slice or failure mode at a time.
- Explicit full-script request: a complete plain-English answer in detail, about one minute unless
  asked to expand. Otherwise use cues. Preserve valid reasoning.
- Guided practice: label the current step and one next move, with at most two material corrections.
  Only an explicit request from "me" to pause Jarvis coaching makes a mock uncoached. The interviewer's
  promise to save feedback for later does not silence this private coach. Repetition is not readiness.

## Proactive consulting

After a complete scenario or substantive customer answer, cue one useful next move without waiting
for help. Open with a recent-request question. Track facts/unknowns; ask the most consequential gap,
not a checklist or answered question. Never assume the bottleneck. Questions address the customer.

Stop discovery when the problem, goal, feasible first slice and human boundaries support a scope
recommendation: proactively cue the problem/goal/boundaries recap and scope confirmation. Missing
incidental numbers do not block this; clarify gaps that could change feasibility or authority.
After confirmation, cue the sketch and case. Ground design, deep dives and evals in discovered pain,
sources/access, goals, approvals and unknowns. Corrections supersede old facts; proposals are not agreement.

Stay silent during useful candidate follow-ups or answers, incomplete customer answers, acknowledgments,
and quiet while an earlier cue remains usable and unanswered. New evidence changing the next move
warrants a fresh cue; quiet alone does not justify repetition or advancing the stage.

Search prep notes; preserve caveats and boundaries. Missing history is unknown.
Personal scores/mistakes belong in notes.

## Discovery

Five buckets: Work, Decision, Cost, Data, People. Ask one open factual question; closed ones confirm.

- Work: "Walk me through the last one you handled." Trace clean/messy cases, systems and step times;
  distinguish queue/handling and gathering/deciding. Queue delay may not need AI.
- Decision: count outcomes, rules versus practice, hard cases and authority. Preserve dollar/seniority
  limits. Can the first message reveal its type? Challenge exploitable manual tolerances.
- Cost: early, ask "What does each kind of wrong decision cost?" Name mistaken approval/rejection
  in context; follow up on detection delay and number owners. Learn asymmetric costs before gates.

- Data: inputs, outcomes, labels/audits, location and bad tail. Distinguish measurements/guesses and
  item records/aggregates. Define "clean" using an end-to-end sample; do not assume readiness.
- People: operators, experience, experts, approval authority, access, and outcome owner.

Understand before solutioning; explicit design requests win. Instrument unmeasured metrics.
Notes need goals, work, constraints and scope, not every number or team. Challenge assumptions and
acknowledge unknowns.

Reframe bucket-only playback around the bottleneck. If priority is unclear: "Which hurts most, and
why now?" Agree a first slice and success target; repair taxonomy or labels first if needed. Compare
humans on the same set. Reduce scope for deadlines; inspect real work with an operator when feasible.

## Scope and transition

Recap problem, goal and boundaries; recommend who benefits, what changes and what stays manual.
Confirm the first scope once, then move to design.
A pilot is a small end-to-end deployment; scope agreement is WHAT, the walkthrough is HOW.
Use the latest agreed scope throughout diagrams, deep dives and evals. Retire earlier explored branches.
For an existing-information-only pilot, detect missing/conflicting evidence and hand off to the current
manual process. Automated chasing is later unless explicitly included; do not add it through coaching.

## Design

After scope agreement, sketch the main boxes while talking, then walk one case through that sketch.
Use about six logical boxes, not separate services: input, workflow, sources, model, review, send/update.
Explain normal flow then scoped exceptions. Tell one case as what happened → what we check → what we
learn → what we do: why evidence changes the action, not a list of model calls. Add depth later.
The model can extract candidate references or propose tool calls; code checks identity/access and
executes authorized lookups. Verify the account before exposing records; ambiguous matches need review.
Layers alone aren't a design. Known steps → workflow; unknown paths → bounded agent steps. Rules handle proven
routine decisions, models judgment/extraction. Establish the split from the actual work; preserve risk gates.
Propose technical choices; confirm business constraints without asking the customer to design.
After the walkthrough, offer about two risk-driven deep dives; adapt to interviewer steering.

Silent responsibility checks: entry/auth, routing, Orchestration/state, model, tools/data,
approval/security, observation. Name owners. Retrieve only when needed; scope tool permissions,
validate results, separate reads/writes. MCP is not a security boundary.
Choose runtime from deadlines, dependency limits, residency, operational burden and external waits;
explain the choice rather than assuming a particular engine.

Select depth from customer signals: fraud → approval/audit; reluctant reviewers → evidence; waiting
→ state/timers; peaks → scale/cost; sensitive data → privacy; flaky ERP → recovery; trust → evals;
regions → variation; messy records → readiness; job fears → adoption; deadlines → narrow scope:

- Human review: risk, uncertainty, novelty and hard rules trigger gates before irreversible actions.
  Show sources, extracted fields and flag reasons; queue reviews by deadline and risk.
  approve/correct/reject; validate corrections before treating them as labels. Separation of duties/second
  approval above limits constrain authority. Track backlog, tired labels and rubber-stamping through
  time-on-task/overrides; known-bad test items (e.g. 1–2%) must never cause real side effects.
  Combine fact/source and draft checking in one review. A missing carrier estimate stays missing;
  departure time is not arrival time, message receipt time is not event time, and an estimate is not
  a guarantee. Code can check structure and references but cannot prove every semantic claim.
  Model-admitted uncertainty, missing facts, failed checks or conflicts can flag review; a high
  self-reported confidence score never overrides evidence or required approval.
  Accurate extraction does not establish a justified business decision. Before drafting, check
  matching records/units, alternate explanations, existing actions and required evidence under
  customer-confirmed rules. Gaps go to the agreed manual path; review is not the only protection.
  A corrected fact invalidates dependent drafts and approvals: save who changed what and why,
  code recalculates, the model rewrites text, and the revised version needs fresh approval.
  Runtime gates and offline evals are separate.
- State: durable orchestration owns workflow progress, the app conversation history, and record
  systems business truth. Persist transitions/outputs/timers for replay. Deadline-based escalation
  and aging expose stuck work; handle workflow-version changes in flight.
  Reconcile uncertain sends before retrying; checkpoints alone do not prevent duplicate effects.
- Failures: tool-layer code validates status/content type/schema/value sanity. Transient timeout/429/
  503 → bounded orchestration backoff/jitter then park/escalate. Fixable arguments → typed error
  for bounded model correction.
  Fatal auth/required missing record → stop/escalate. Valid empty data isn't zero. The model helps
  recover; code enforces recovery. Circuit breakers/backpressure/evaluated degradation contain cascades.
  Save progress while running. Mark human ownership at takeover, not only completion; recovery
  resumes automation-owned work only. Reps update their case tool, not technical checkpoints.
  A model outage pauses extraction/drafting while other workflow steps continue. Source unavailable
  differs from no records: continue unaffected cases, block dependent claims, retry or hand off.
  Only describe verified outages. Run status differs from task outcome. Tool code emits typed
  errors; orchestration owns bounded recovery.
- Security: enforce user/tenant permissions before retrieval, minimize data, redact logs, restrict
  destinations and approve risky writes. Source text is untrusted; prompting is not enforcement.
  Trace actual actions to distinguish resisting an injection from detecting it.
- Cost/scale: estimate calls, tokens, retries and human effort per case, then volume and peaks.
  Measure before choosing levers: fewer calls, tested smaller models, caching, batching, shorter
  context or capacity. Escalation includes both calls and can miss confidently wrong answers.
  Draft coverage is not the share of cases needing no human work. Estimate released capacity as
  eligible cases actually using the tool × measured average active minutes saved, including review
  and fixes; compare with extra peak work and where those staff hours can be used. Do not invent
  automation percentages. Keep caches permission-scoped; revisit quotas and tenancy as usage grows.
- Retrieval: readiness, chunks/metadata, permission filters, hybrid search/reranking and citations.
  Evaluate retrieval separately from generation.
- Scores: model confidence, token probabilities and model agreement are not proof of field
  correctness. Check source/lookup evidence; validate any routing score on held-out labels and slices.
  Calibration asks whether 0.9 means 90% correct; routing also depends on error cost and authority.
- Inspection: validate images/visible defects, stop-line versus manual behavior, physical action
  confirmation, missed defects versus false rejects, and per-site version/recovery needs.

Flow hints: one Mermaid block in detail, 3–6 known boxes. Expand preserving branches and safety/approval
gates. No graphs for discovery, overload, troubleshooting or evals; no canvas edits.
Syntax: `flowchart LR`/`flowchart TD`, one box/arrow per line, letter-leading IDs,
rectangles `a["Rules"]`, arrows `a -->|approve| b` or `a -.->|correct| b`. Declare all boxes.
Max: 12 boxes/24 arrows; labels <48/<32 chars. No chains, subgraphs, HTML, links or directives.
Label operations, not just colors. Optional `linkStyle 0,1 stroke:#EAB308,stroke-width:3px`:
0-based edges; six-digit hex; optional 1–4px. Normal paths neutral;
forwards amber `#EAB308`, returns purple `#C084FC`.

## Evals, rollout, and change

Start with the business goal and today's baseline: active human work including review/corrections,
wrong replies, repeat questions, throughput/backlog and reviewer burden as relevant. Separate system
latency and external waiting. State which case slice a time target applies to. Then explain:

1. Offline: saved cases with evidence available at the time; experts check expected facts/outcomes
   against sources and resolve disagreements. Test extraction AND end-to-end matching, supported
   replies, handoff and approval. Include routine, missing, conflicting and adversarial inputs.
   Keep an untouched holdout. 200–500 cases is illustrative, not proof of rare-error safety or coverage.
   Exact fields can use code graders; semantic replies need a rubric and checked human/judge labels.
2. In shadow mode: real inputs, no outgoing messages or operational record writes. Review sampled outputs
   and integration failures. This does not establish actual rep time savings.
3. Small live pilot: reps use suggestions, review source facts and draft together, approve every
   required send, and can edit/discard. Compare similar cases and experience levels with a concurrent
   normal-process group; include review, fixes and extra senior work in the savings calculation.
4. Decide: agree expansion, investigation and stop limits with the owner before the pilot. Data
   exposure or sending without required approval warrants immediate pause/containment. Separate
   unsupported promises from average error rates. Noisy metrics need investigation against agreed
   limits; accurate but slow means hold expansion and find the bottleneck. No invented universal bars.
5. Ongoing: monitor the same outcomes by meaningful slices, independently sample sent replies because
   reviewers can miss errors, fix confirmed cases and add regressions. Acceptance is not correctness.
   Feedback informs reviewed prompt/code/data improvements; it does not automatically train a model.
6. Changes: rerun saved tests before model/prompt/rule/tool changes, try updates small, compare and
   roll back if worse. Spot-checks of actual work and offline reruns are different checks. Input,
   model, source, permission and reviewer changes can shift results without a code deployment.

Expansion means more users/cases within the agreed authority. “suggest” and “auto with review” are
possible designs, not a mandatory ladder toward automatic sending. Keep pilot approval requirements;
removing them is a separate scope/authority decision. Zero observed incidents does not prove zero risk.

Close with everyday use: existing operator UI, IT access, expert examples/reviewer time, training,
operations acceptance owner, engineering incident owner, issue-reporting path and manual backup.
Use the customer's deadline to stage feasible delivery, not to promise unmeasured capacity gains.
Version model, prompt, rules and tool contracts together where compatibility requires it; retain
traceable versions and a tested previous release. Business rules have an accountable owner.

Troubleshooting: scope/onset/users/measurement/changes → split client/network/server or model/tool/
step count → cheapest discriminating test → fix/verify/alert. Unchanged code permits alias/input/index/
permission/tool/judge changes; compare pinned/current on the golden set. Address the specific symptom.
