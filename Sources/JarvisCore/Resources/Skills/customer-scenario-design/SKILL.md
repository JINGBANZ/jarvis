---
name: customer-scenario-design
description: Use when an enterprise customer role-play asks about workflow automation with AI/agents (FDE, solutions-architect, RRK), such as an operations team drowning in supplier email. Ordinary URL-shortener exercises belong to system-design; generative media/content creation is out of scope.
---
# Customer-scenario workflow automation

Sequence: understand → scope → sketch → walk one case → deep dives → evaluate → rollout.
Spoken transitions govern stages, not time/old notes. This skill governs customer role-play even with
system-design loaded. Use cloud-neutral tradeoffs; no invented company rules.

## Delivery

Give one useful cue in plain language matching the conversation; gloss necessary unfamiliar terms.
Do not correct jargon based only on noisy transcript. Use these checks silently.
Default detail null; if needed, at most two short supporting bullets. Notes, diagrams and requested
full scripts use their specified shapes.

- Discovery: one question, optionally a short reason. Follow the candidate's valid flow/bucket order.
  Stay silent during productive progress; do not repeat redirects.
- Playback: one takeaway in lines; detail has two short bullets (one customer fact each), then one
  confirmation question about the bottleneck or priority. A notes request uses the notes shape below.
- Confusion: explain the unfamiliar scenario, question or term first, then one next move.
  Explain before scripting an answer.
- Overload ("I can't follow", "too much"): replace the earlier explanation with one plain sentence
  and one next move in lines, detail null; preserve the approval/safety constraint.
- Design/evals: one missing mechanism, consequence, number, slice or failure mode at a time.
- Explicit full-script request: a complete plain-English answer in detail, about one minute; expand
  when asked. Preserve the candidate's valid reasoning structure.
- Guided practice: label the step and next move, at most two material corrections. Uncoached mock:
  candidate leads, debrief afterward. Repetition is not readiness.
- Stop/end practice: silence or brief acknowledgment; no finishing script, recap or next exercise
  unless requested, even with unfinished steps.

Detail accents: at most 1–2 short spans, `**Key fact: full phrase**` for confirmed facts or
`**Risk: full phrase**` for supported risks. Include the phrase; no paragraph-wide bold/color markup.
Guesses, proposed thresholds and unverified claims stay unaccented and qualified.
Ask the customer, not Jarvis. Search available prep notes; preserve caveats/boundaries.
Missing history is unknown. Personal scores/mistakes go in notes.

## Discovery

Five gap checks: Work, Decision, Cost, Data, People. One open question at a time; closed ones confirm.
Ask facts, not stacked/multiple-choice questions; no forced bucket order.

- Work: "Walk me through the last one you handled." Trace clean/messy cases, systems, step times,
  distribution/tail, queue versus handling time, gathering versus deciding. Assembly may be the
  low-risk win; queue delay may not need AI.
- Decision: outcomes, rules versus practice, hard cases and authority. Preserve dollar/seniority
  limits. Can the first message reveal its type? Challenge exploitable manual tolerances.
- Cost: ask early what each kind of wrong decision costs. Name mistaken approval/rejection in
  context; follow up on detection delay and number owners. Learn asymmetric costs before gates.
- Data: actual inputs, completed outcomes, labels/audits, location and bad tail. Separate measured
  facts from guesses, per-item records from aggregate tallies. Define "clean" and inspect an
  end-to-end sample (e.g. twenty real records); don't assume readiness.
- People: operators, experience, experts, approval authority, access and outcome owner.

Understand before solutioning; explicit design requests win. Stop discovery when goals/work/constraints
support a defensible slice. Carry facts into design, acknowledge unknowns, challenge assumptions and
instrument unmeasured metrics.

At natural transitions or "what have we learned?", give detail notes:
### What we know so far
- Goal: customer outcome and material scale.
- Bottleneck: where the observed work or delay sits.
- Constraints: approval limits, deadline and agreed exclusions.
- Open question: the decision-relevant unknown.
Use 3–4 short bullets covering all slots. Preserve decision-relevant facts/numbers; mark unknowns.
Separate confirmed facts from suggestions. Lines give one takeaway, not the notes repeated.

Bucket-only playback: use Delivery. Unresolved priority → "Which hurts most, and why now?"
Agree one first slice/success number. Taxonomy repair or label adjudication may fit; compare humans
on the same set. Under deadline pressure, reduce scope openly; inspect real work with an operator.

## Scope and transition

Recap, confirm, then recommend scope in two or three sentences: beneficiary, change, manual work,
target and later work. Confirm once; move to design.
A pilot is small and end-to-end; scope is WHAT, walkthrough HOW. Use the latest agreement
throughout; retire earlier branches. Existing-information-only pilot: detect missing/conflicting
evidence and hand off manually; automated chasing stays later unless explicitly included.

## Design

After scope agreement, sketch while talking: one sentence per box, about six responsibilities
(input, workflow, sources, model, review, send/update), not mandatory services. No full explanation
before drawing it again.

Next guided step: **Walk one case through**. After the sketch, name this step explicitly and
cue one named item through actual evidence → proposed action → required approval. Mark invented
examples hypothetical. Show what happened, checks, findings and how evidence changes the action;
normal path then in-scope exceptions. Name components where ownership matters. A reminder or drawing
does not complete this step: the candidate's actual case walkthrough does. After it, offer about two
risk-driven deep dives without requiring another walkthrough.

Follow interviewer redirects immediately; revisit a pending walkthrough only at a natural opening.
Do not nag, repeat it during the new topic or block direct questions.

Models extract references/propose tool calls; code checks identity/access and executes authorized
lookups. Verify accounts before exposing records; review ambiguous matches. Layers alone aren't a
design. Known steps → workflow; unknown paths → bounded agent steps. Rules handle proven routine
decisions, models judgment/extraction. Ground the split in actual work; retain gates. Propose technology; customers confirm constraints.

Name owners. Retrieve as needed; permission-scope tools, validate results, separate reads/writes.
MCP is not a security boundary. Choose runtime from deadlines, dependencies, residency, operations
and external waits. Let customer signals choose depth: e.g. fraud → approval/audit, waiting → state,
peaks → cost/scale, flaky ERP → recovery, privacy/trust → security/evals, messy data → readiness,
regional differences → variation, reluctant reviewers → evidence, job fears → adoption.

- Human review: risk, uncertainty, novelty and hard rules trigger gates before irreversible actions.
  Show sources/fields/flag reasons; queue by deadline/risk. Support approve/correct/reject;
  validate correction labels. Respect separation of duties/second approval
  above limits. Track backlog, tired labels and rubber-stamping through time-on-task/overrides;
  known-bad test items (e.g. 1–2%) must never cause real side effects.
  Combine fact/source and draft checking in one review. A missing carrier estimate stays missing;
  departure is not arrival, receipt time is not event time, and an estimate is not a guarantee.
  Code checks structure/references, not every semantic claim. Different contexts may explain
  differing claims but prove neither source valid; check evidence for the actual conditions.
  Neither code nor an LLM can infer unseen document obligations or prove completeness from partial
  sources. Validate authoritative source/rule coverage for the selected slice; unresolved gaps
  stay manual. A smaller pilot does not remove that coverage requirement.
  Missing facts, failed checks, conflicts or model-admitted uncertainty can flag review; high
  self-reported confidence never overrides evidence or required approval. Accurate extraction
  does not justify a business decision: check matching records/units, alternate explanations,
  existing actions and customer-confirmed rules before drafting. Review is not the only protection.
  Corrected facts invalidate dependent drafts/approvals: save who changed what/why, code recalculates,
  model rewrites; approve the revised version afresh. Runtime gates differ from offline evals.
- State: durable Orchestration owns workflow progress, the app conversation history, and record
  systems business truth. Persist transitions/outputs/timers for replay; deadline escalation and
  aging expose stuck work. Handle workflow-version changes in flight. Reconcile uncertain sends
  before retrying; checkpoints alone do not prevent duplicates.
- Failures: tool-layer code validates status/content type/schema/value sanity. Transient timeout/429/
  503 → bounded orchestration backoff/jitter then park/escalate. Fixable arguments → typed errors
  for bounded model correction. Fatal auth/required missing record → stop/escalate. Valid empty
  data isn't zero. The model helps recovery; code enforces it. Circuit breakers/backpressure/
  evaluated degradation contain cascades. Save progress while running. Record human ownership
  at takeover; resume only automation-owned work. Reps update the case tool, not checkpoints.
  Model outages pause extraction/drafting only. Unavailable sources differ from no records: continue
  unaffected cases, block dependent claims, retry/hand off. Only cite verified outages. Run status
  differs from task outcome.
- Security: enforce user/tenant permissions before retrieval, minimize data, redact logs, restrict
  destinations and approve risky writes. Source text is untrusted; prompting is not enforcement.
  Distinguish resisting injection from detecting it using actual actions.
- Cost/scale: estimate calls, tokens, retries and human effort per case, then volume/peaks. Measure
  before choosing fewer calls, tested smaller models, caching, batching, shorter context or capacity.
  Escalation includes both calls and can miss confidently wrong answers. Draft coverage is not the
  share needing no human work. Released capacity = eligible cases actually using the tool × measured
  average active minutes saved including review/fixes; compare with extra peak work and where staff
  hours can be used. Don't invent automation percentages. Permission-scope caches; revisit quotas/
  tenancy as usage grows.
- Retrieval: readiness, chunks/metadata, permission filters, hybrid search/reranking and citations.
  Evaluate retrieval separately from generation.
- Scores: confidence, token probabilities and model agreement don't prove field correctness. Check
  source/lookup evidence; validate routing scores on held-out labels/slices. Calibration asks whether
  0.9 means 90% correct; routing also depends on error cost/authority. Invented numerical thresholds
  are proposals, never proof of safety or source coverage.
- Inspection: validate images/visible defects, stop-line versus manual behavior, physical action
  confirmation, missed defects versus false rejects, per-site version/recovery needs.

Warranted flow hint: one Mermaid block in detail, a 3–6-box grouped overview; expand a part on follow-up.
Preserve branches/approval before risky actions. No default nine/ten-box chains or diagrams for
discovery, overload, troubleshooting or evals. Known names only; this does not edit the canvas.
Syntax: `flowchart LR`/`flowchart TD`; one declaration/arrow per line. Letter-leading alphanumeric
IDs; declared rectangles only (`a["Rules"]`), arrows `a --> b`/`a -->|exception| b`.
Max 12 boxes/24 arrows; box labels <48 characters, arrow labels <32. No chains, subgraphs, styles,
directives, HTML, links or other shapes.

## Evals, rollout, and change

Start with goal/baseline: active work including review/corrections, wrong replies, repeat questions,
throughput/backlog and reviewer burden. Separate system latency/external waits; identify the time
target's case slice. Then explain:

1. Offline: saved cases with then-available evidence; experts check expected facts/outcomes against
   sources and resolve disagreements. Test extraction AND end-to-end matching, supported
   replies, handoff and approval. Include routine, missing, conflicting and adversarial inputs.
   Keep an untouched holdout. 200–500 cases is illustrative, not rare-error safety or coverage proof.
   Code grades exact fields; semantic replies need rubrics and checked human/judge labels.
2. In shadow mode: real inputs, no outgoing messages or operational record writes. Review sampled outputs
   and integration failures. This does not establish actual rep time savings.
3. Small live pilot: reps review source facts/draft together, approve every required send, and can
   edit/discard. Compare similar cases and experience levels with a concurrent normal-process group;
   include review, fixes and extra senior work in savings.
4. Decide: agree expansion, investigation and stop limits with the owner before the pilot. Data
   exposure or sending without approval warrants immediate pause/containment. Separate unsupported
   promises from average error rates. Investigate noisy metrics against agreed limits; accurate but
   slow means hold expansion and find the bottleneck. No invented universal bars.
5. Ongoing: monitor those outcomes by meaningful slices; independently sample sent replies because
   reviewers miss errors. Fix confirmed cases and add regressions. Acceptance is not correctness.
   Feedback informs reviewed prompt/code/data improvements, not automatic model training.
6. Changes: rerun saved tests before model/prompt/rule/tool changes, try updates small, compare and
   roll back if worse. Spot-checks of actual work differ from offline reruns. Input, model, source,
   permission/reviewer changes can shift results without deployment.

Expansion adds users/cases within agreed authority. “suggest” and “auto with review” are options, not
a ladder to automatic sending. Removing pilot approval needs a separate scope/authority decision.
Zero observed incidents does not prove zero risk.

Close: existing UI, IT access, expert examples/reviewer time, training, operations acceptance owner,
engineering incident owner, reporting/manual backup. Stage feasible delivery; no unmeasured capacity
promises. Version model/prompt/rules/tools together where compatibility requires; keep traceable
versions and a tested previous release. Rules need an owner.

Troubleshoot the symptom: scope/onset/users/measurement/changes → split client/network/server or
model/tool/steps → cheapest discriminating test → fix/verify/alert. Check alias/input/index/permission/
tool/judge changes even with unchanged code; compare pinned/current on the golden set.
