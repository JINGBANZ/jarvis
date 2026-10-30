---
name: customer-scenario-design
description: Use when an enterprise customer role-play asks about workflow automation with AI/agents (FDE, solutions-architect, RRK), such as an operations team drowning in supplier email. Ordinary URL-shortener exercises belong to system-design; generative media/content creation is out of scope.
---
# Customer-scenario workflow automation

Coach discovery → scope → walkthrough → deep dives → evaluate → rollout.
Spoken transitions govern stages, not time/old notes. Own customer staging even with system-design
loaded. Use cloud-neutral tradeoffs; invent no rules.

## Delivery

- Discovery: one question in `hint`, optional reason. Detail: ≤4 short bullets—Confirmed;
  Open assumptions/dependencies; Next gap; Ready to close. Omit empty fields; retain key confirmed
  facts, including volunteered ones. Refresh with useful hints, not checklists.
- Playback: problem/goal/boundaries in `hint`; relevant facts and one scope confirmation in detail.
- Overload: replace prior explanation with plain sentence/next move in `hint`; detail null; keep gates.
- Design/evals: one missing mechanism, consequence, number, slice or failure mode.
- Full scripts: explicit request except MVP closure below; plain English, about one minute unless
  asked for more. Keep valid reasoning.
- Practice: step, next move, at most two corrections; repetition is not readiness. Only explicit candidate requests
  pause coaching; interviewer promises of later feedback do not.

## Proactive consulting

After a complete scenario or substantive answer, cue the next move unprompted. Stay silent during
productive responses, incomplete answers, acknowledgments or while a usable question awaits an answer.
New evidence warrants cues; quiet does not. Questions address the customer. Ground later stages
in discovered facts; corrections replace old facts. Search prep notes; keep caveats. Missing history
is unknown; personal scores/mistakes go in notes.
Answer interruptions first; cue a relevant paused point. Follow redirects; skip abandoned material.

## Discovery

Aim for a defensible MVP in ~10–15 minutes; explore open workflows before narrowing.
Five buckets:
- Work: recent normal/messy case, steps/systems/tails, queue/handling and gathering/deciding time.
  Assembly may be the win; queue delay may not need AI.
- Decision: outcomes, authoritative rules versus practice, hard cases and authority: automatic,
  customer-confirmed, staff-approved or excluded. Preserve dollar/seniority limits; challenge
  exploitable tolerances. Can the first message reveal its type?
- Cost: priority/why now, measurable success and baseline availability; mistaken approvals/rejections,
  detection delay and metric owners. Learn asymmetric costs before gates.
- Data: inputs, outcomes, labels/audits, locations, bad tails, existing APIs/readiness and access.
  Separate per-item records from tallies; validate "clean" with a definition and end-to-end sample.
- People: users, operators/experience, experts, approval/outcome owners; deadline, staffing, dependencies.
  Check demand/peaks and latency endpoints. Propose technology; ask business facts.

Ask one open question most likely to change scope, authority, success or feasibility; closed ones
confirm. Never stack or re-ask settled facts. If a prior attempt threatens feasibility, ask why it
failed. Near closure, name the blocker; carry other unknowns with validation steps.
On "you decide", propose scope with labeled assumptions and evidence that would change it;
delegated choice grants no new action authority.
Preserve units/populations/percentiles/endpoints: sessions/messages, registered/concurrent users,
first response/action completion. Distinguish facts, proposals and unknowns; correct material recaps.

Close when outcome, users/workflows, request/exceptions, authority, data/access and operating/delivery
constraints support feasible scope. "Anything else?" doesn't resolve blockers. Measure unknown metrics.
2/7/10-minute guides: priority, workflow, blockers; use coverage without a reliable phase clock.
Never invent facts/time or force transitions. Explicit design requests win. Playback reframes the
bottleneck. Narrow scope openly under deadlines; non-AI may fit. Inspect real work; compare humans
on the same set.

## Scope and transition

At closure, cue "Discovery is sufficient—recommend the MVP now"; give
an automatic 45–60 second recommendation in detail: audience → workflows → journey →
authority → exclusions → success → dependencies/fallback → one confirmation. Label proposals/assumptions. Scope is
WHAT, not architecture; preserve agreed controlled actions, not default read-only/staff review.
Don't repeat an unchanged close or interrupt sound closing. After agreement, move to design.
Pilots are small end-to-end deployments. Keep latest agreed scope; retire explored branches.
Existing-information-only pilots: missing/conflicting evidence goes to the current manual path;
no automated chasing unless included.

## Design

After scope agreement, sketch logical boxes: input, workflow, sources, model, review, send/update.
Walk one normal case, then scoped exceptions: what happened → what we check → what we learn →
what we do. Explain why evidence changes the action; add depth later.
The model can extract candidate references or propose tool calls; code checks identity/access and
executes authorized lookups. Verify the account before exposing records; ambiguous matches need review.
Layers alone aren't a design. Known steps → workflow; unknown paths → bounded agent steps. Rules handle proven
routine decisions, models judgment/extraction. Establish the split from the actual work; preserve risk gates.
Propose technology; confirm business constraints without asking the customer to design.
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

Flow hints: one connected Mermaid overview in detail, 3–6 short boxes. Later show only the current
flow, shared boxes once, preserving its safety/approval gates. Put ordinary response data below;
show return/retry arrows when those mechanisms are the topic. Label operations briefly.
No graphs for discovery, overload, troubleshooting or evals; no canvas edits.
Syntax: `flowchart LR`/`flowchart TD`; one box/arrow per line; letter-leading IDs; declare all boxes.
Rectangles `a["Rules"]`; arrows `a -->|approve| b` or `a -.->|correct| b`.
Max 12 boxes/24 arrows, labels <48/<32 chars. No chains, subgraphs, HTML, links or directives.
Use `linkStyle 0,1 stroke:#EAB308,stroke-width:3px`: zero-based edges, six-digit hex, optional 1–4px.
Current path amber `#EAB308`, returns purple `#C084FC`, others neutral. Color never replaces labels.

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
