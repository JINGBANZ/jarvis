# Coaching-quality instruction regression cases

`coaching-quality.json` contains synthetic inputs and semantic pass criteria for performance
reasoning, adaptive verification, comprehension, bounded delegation, and distinguishing tests.
It also includes ordinary-coding and system-design controls. No private session material is needed.
These are development regressions, not held-out transfer tests: they informed the guidance and remain
useful for checking the known failures after edits. Removing answer-specific examples from the skill
does not make these cases held out. Report their results as regression evidence. A transfer claim
requires separate, previously unused problems from different domains, evaluated without tuning the
guidance to their answers; report those results separately.

Run each input in a fresh model conversation with the production `JarvisPrompts.Coach.system`
base instructions, `speakTool` guidance, and the named bundled skill bodies
already loaded. Give the model only `input`, never `pass`. Offer the normal coach actions or,
for a CLI instruction-level evaluation without tools, request a JSON representation of one
`speak`, `stay_silent`, or `capture_screen` action. Do not grant filesystem, browser, or shell tools.
Keep the same provider, model, instructions, and cases for the before/after comparison, changing
only the guidance under test. Preserve responses locally with the model identity and revision.

Review the actual response against each case's `pass` criterion. Record pass, fail, or not observed
with the relevant quote. Check all parts: a correct complexity formula does not excuse an invented
bottleneck, and a correct explanation does not excuse repeating an irrelevant testing reminder.
Do not score by matching wording in a skill, by keyword counts, or by the model's self-assessment.
Repeat failures and uncertain cases; a single good response does not establish a reliable rate.
The productive-coding case should produce silence. The system-design control should use a small
cross-gateway counterexample without prescribing the complete solution.

For additional verification-reminder coverage, evaluate these independent variants:

- **Verified completion:** supply an actual relevant test output before the candidate finishes.
  The coach should acknowledge the evidence's scope without another generic run-tests reminder.
- **Unsupported completion:** candidate intends to finish solely because the other assistant says
  tests passed. A focused verification reminder is useful here; reducing repetition must not remove it.

These cases evaluate instruction behavior, not transcription, tool parsing, rendering, skill
selection, or speech/shortcut coordination. They do not replace the signed-app scenario D and
real-browser checks documented in `wiki/live-e2e-tests.md`. Report those checks separately.

## Customer-scenario workflow coaching

The `customer-*` cases cover enterprise workflow automation (FDE/RRK-style customer role-play),
not generative media/content creation. They exercise early solutioning, stacked questions, asymmetric
error costs, data readiness, playback, shape-first architecture, routing, runtime proposals, typed
failure handling, rollout gates, silent degradation, calibrated scores, bundle rollback, unavailable
prep notes, explicit stage transitions, and productive-answer silence. The co-loaded case checks that
`system-design` does not restart its stage sequence during a customer scenario. Timings and thresholds
in the skill are examples to adapt to the customer's constraints, not verified company scoring rules.

Run them with the same production base and speak guidance as above. Keep `pass` criteria hidden from
the responding model. Catalog/content assertions establish packaging and a few omissions only; they
cannot score these behaviors. The preloaded URL-shortener and media controls test noninterference,
not whether the model would select the new skill in the first place.

For selection, separately offer only the production catalog descriptions and loader, with no skill
bodies preloaded. Ask the model to select for (1) the supplier-email customer role-play, (2) an ordinary
URL shortener, and (3) generative marketing images/videos without workflow automation. Record actual
`load_skill` choices: the customer skill fits (1), not (2) or (3). Other applicable skills may load;
there is no runtime exclusive classifier. Loading `system-design` too is not itself a failure if the
customer skill governs the customer segment. Evaluate selection separately from the preloaded cases.

Preserve each response with case ID, prompt/skill revision, provider/model and evaluation method.
Fresh subagent probes are instruction-level development evidence and must be labeled as such: they
retain the host agent's surrounding instructions and are not production-provider or signed-app runs.
A baseline with no customer skill can expose a missing rule; a baseline that already passes does not
prove the new skill improves that case. Report unexecuted cases as not observed, repeat uncertain or
failed outputs, and do not infer a reliability rate from a single sample. These cases require neither
private interview notes nor captured session data.

## Compact customer cues: development probes (2026-09-29)

The five additional cases are synthetic library discovery/playback, theatre overload, museum flow,
and recreation-centre script requests. They check the delivery contract independently of the existing
technical-content cases. Review semantic usefulness and preserved gates as well as response shape;
word counts alone cannot establish coaching quality. For graphs, inspect grouping, decision branches,
and approval before release, not just the number of boxes.

Five baseline and five revised responses used separate fresh subagents (`fork_turns: none`), one case
per agent. Each bootstrapped one prompt file containing the production static coach base, speak tip/detail
guidance, the loaded customer skill, and the input. The responding agent never received `pass`.
After bootstrap, it produced a JSON coach action without further tools. The provider/model was the
same inherited Codex host model; its exact provider snapshot was not exposed. Host system/developer
instructions remained, so these are instruction-level regressions, not isolated production-provider,
loader-selection, rendering, or signed-app evaluations. There was no private session material.

| Case | Baseline observation | Revised candidate observation |
| --- | --- | --- |
| `customer-discovery-cue` | Pass: asks “Walk me through the last damaged-book report you handled.” | Pass: retains that single question and adds one short reason. |
| `customer-playback-cue` | Fail: “Show the two bottlenecks” expands into volume, handling time, delay, owner, missing target and error costs across oversized lines. | Pass: one bottleneck takeaway; two facts (“Rare-book cases wait four days” and preservation-lead ownership); one priority confirmation. |
| `customer-overload-cue` | Fail: walkthrough plus several approval/pending/declined sentences. | Pass: “The system prepares each refund, and a manager approves it before any money is returned,” then one walkthrough move; detail is null. |
| `customer-graph-overview` | Fail: nine serial boxes, one per known step. | Pass: six grouped boxes, explicit curator approval, and ineligible/unapproved paths to hold; handoff and arrival remain visible. |
| `customer-explicit-script` | Pass: full playback in detail with customer facts and confirmation. | Pass: full playback remains available in detail; the compact default does not suppress it. |

An initial revised playback probe had two bullets but bundled queue delay and decision ownership into
one bullet, exceeding the two-fact contract. The recipe was tightened to one customer fact per bullet;
a fresh repeat produced the revised result above. This is one additional development sample, not a
held-out confirmation. Playback decreased from 54 to 42 whitespace-delimited words, overload from
46 to 31; the explicit script remained substantive. Several responses still exceeded the generic
under-12-words-per-line guidance, including revised playback, overload, and graph lines. These passes
refer only to the new semantic delivery criteria, not every production coach constraint. A single
sample per case establishes neither a reliability rate nor transfer to unseen scenarios. Other cases
were not rerun in this comparison.

Skill revisions (SHA-256 of the whole Markdown file): baseline
`606a4387a46db112a4a154a3472631c518c6ede460dcadb945395fed00df1d03`;
five-case revised candidate `3ac255349cf6937329bd529ceb711d892f66fc25f290d4d0cf5bf825ca2a1638`.

A final wording correction scopes 3–6 boxes to the overview and allows a focused follow-up sketch
when warranted, without requiring an explicit request. Only `customer-graph-overview` was repeated
on this revision in another fresh agent. It passed: six grouped boxes, curator approval before
release, ineligible/denied paths to “No release,” and handoff/arrival retained. Its single overlay
line contains 12 words, so it still misses the generic under-12-words guidance. This opening-sketch
probe does not evaluate autonomous follow-up-sketch selection; the wording correction was checked by
inspection. The other four case results above belong to the earlier candidate and were not rerun.
Final skill SHA-256: `6ebbe89d7d0fdbe6247e8fddc9630d98640f0741729dd28d5e6ac63ccc010420`.
The final body is 14,818 UTF-8 bytes, within the existing 15,000-byte packaging limit.
Full synthetic responses and prompt/revision metadata were retained locally for review; they are not
production-session captures or committed evaluation artifacts. The repository Gate remains separate
packaging/code evidence and does not run these semantic probes.

## Scope, sketch, and evaluation sequence probes

The scope-to-sketch, scope-stays-manual, eval-short-complete, shadow-time-claim and
human-takeover-recovery cases check the current six-step framework. They preserve a short recap,
separate scope from design, keep the latest scope through later answers, distinguish shadow from
measured human effort, and prevent resumed automation from competing with a human owner.

A fresh-context skill-reading agent produced baseline cues for five related synthetic cases before
editing. The drawing cue explicitly said to explain a whole case first and then draw it, reproducing
the duplicate-explanation problem. Its other cues largely passed; the baseline already distinguished
shadow quality from realized savings. After the revision, a fresh read in the same evaluation agent
produced six cues: direct scope-to-design transition, sketch while explaining then walkthrough,
compact complete evaluation, no shadow-based time claim, manual exception scope retained, and human
ownership recorded at takeover. The responses were manually reviewed. These are single-pass
instruction-level development probes; the revised pass retained the baseline evaluation conversation.
They are not independent transfer evidence, repeated reliability measurements, production-provider
runs, or signed-app tests. The new fixture inputs/criteria are retained for repeatable future runs;
the production harness was not used for these probes. Subsequent reference-text compression and
catalog wording were inspected separately, not counted as additional semantic runs.

The build/catalog Gate verifies packaging, deferred loading, and existing app tests. It does not prove
coaching behavior or deploy the updated skill into a running app.

## Concrete cases, decision validity, and capacity probes

Four synthetic development fixtures cover natural case narration, accurate extraction versus a
justified business decision, corrections invalidating dependent approval, and measured human
capacity versus draft coverage. They contain no private practice transcripts or customer records.

Before editing, one fresh-context subagent read the baseline bundled skill and answered four
related repair-depot scenarios. A separate fresh-context subagent read the revised skill and
answered the same four inputs. Each agent answered all four inputs in a single conversation;
there was no fresh conversation per case. Neither received the pass criteria. Both used the
inherited Codex host model with host instructions retained, without the production coach prompt,
speak tool, provider harness, loader, or signed app. These are single-pass instruction-level
probes, not production coaching tests or held-out transfer evidence.

| Behavior | Baseline observation | Revised observation |
|---|---|---|
| Natural case walkthrough | Pass: apparent eight-part shortage, evidence and manual exceptions explained as a case. | Pass: a possible separate delivery explains why a discrepancy does not yet justify a claim; approval retained. |
| Facts versus business validity | Pass: “not that the supplier owes a claim”; notes and evidence checked. | Pass: explicit matching records/units, alternate explanations, existing claims and customer rules. |
| Corrected fact after approval | Pass on approval invalidation: “Changing 40 to 14 invalidates the earlier approval.” Arithmetic ownership was not explicit. | Pass: code recalculates; model rewrites; revised version requires fresh approval. |
| Capacity versus draft coverage | Pass: review/corrections included and measured time savings multiplied by case volume. | Pass: actual adoption and average active minutes saved yield released hours, compared with peak workload and usable staffing. |

The baseline already handled the core scenarios; these samples do not demonstrate a measured
quality improvement. The edit makes the intended mechanisms explicit and adds repeatable regression
criteria. The committed correction fixture also explicitly challenges model-owned arithmetic;
that exact added phrase was not present in the paired probes and remains unobserved in the
production evaluation harness. All four committed fixtures should be evaluated using the protocol
at the top of this document before making a production reliability claim. Catalog/build checks
remain packaging evidence only; the running app is not updated by editing this bundled source.

## System-design progression and comprehension probes

The eight `system-*` cases added for architecture entry, scaling comprehension, batch replay,
proposed batching, gateway-owned ingestion, deep-dive entry, productive design, and requirements
stage are synthetic development regressions. They check diagram delivery, responsibility ownership,
concrete explanations, stable advice, and restraint. They contain no private interview records.

One fresh-context subagent read the baseline production coach/action and speak source guidance plus
system-design skill and answered all eight inputs. A separate fresh-context subagent read the same
sources with the revised skill and answered the same inputs. Pass criteria were hidden. Each agent
answered the group in one conversation, not a fresh conversation per case. These inherited host-model
probes retain host instructions; they do not execute the production prompt composer, provider,
tool loop, renderer, or signed app. They are not held-out transfer or reliability measurements.

| Case | Baseline observation | Revised observation |
|---|---|---|
| Architecture entry | Diagram present, but validation ownership not stated. | Diagram names ingestion validation and lines put success after durable logging. |
| Scaling comprehension | Explains many events per upload, but omits batching delay and flush bounds. | Concrete 100-event example; downstream batching, durable API acceptance, size/time flush, and archival lag distinguished. |
| Batch replay | Same range/name explained; conditional creation not explicit. | Fixed range, create-if-absent, replay and offset commit explained in one example. |
| Proposed batching | Keeps downstream batching and explains memory-loss risk. | Also distinguishes delaying acknowledgment from acknowledging before durability. |
| Gateway-owned ingestion | Accepts managed integration, with an unnecessary unchanged-flow diagram. | Accepts existing responsibility with a brief text answer. |
| Deep-dive entry | Names a crash but leaves response/recovery to the candidate. | Gives a concrete archival retry mechanism and replay/lag trade-off. |
| Productive design | Silent. | Silent. |
| Requirements stage | Scope question, no architecture. | Scope question, no architecture. |

The baseline already produced a graph in this short synthetic context, so these samples do not
establish improved diagram frequency in a long session. The revised architecture opening still has
one 12-word line, missing the generic under-12-word guideline. The archival examples assume an
exclusive object namespace and repeatable batch contents; they are coaching illustrations, not a
complete storage protocol. Other existing cases were not rerun semantically. Evaluate the fixtures
with the fresh-conversation protocol above before claiming production-provider improvement.

Whole-file SHA-256 revisions: baseline
`97b0edacb21ec354ba150ebdc1ed98968e54990896d9640a8bfffe327c30c20c`; revised
`b6e87dd1c005f58ee409fe811af227be8969187875c8e1d6379bb35b7486c7256`.
The repository Gate verifies packaging and code behavior separately; it neither scores these
semantic cases nor installs the revised skill into a running app.

## Proactive consulting regression coverage

The `customer-proactive-*`, `customer-explicit-no-coaching`, and
`customer-discovery-guides-design` cases exercise unsolicited opening/follow-up cues, discovery
sufficiency and recap, a material feasibility gap, candidate progress, acknowledgments, repetition,
explicit coaching opt-out, and discovery evidence carried into design. Run them with the same
production policy and loaded skill as the other cases. A passing Gate checks packaging and harness
behavior; it does not execute these semantic cases or establish live coaching quality.

The reported session supplies a baseline failure: a complete scenario and later workflow answer
reached the model with this skill loaded, and the model returned `stay_silent`. Synthetic before/after
model evaluation of this change is not observed; external evaluation requires approval. No private
session transcripts or screenshots are included in the regression fixtures.

## Stage-reference and diagram-style probes

The six `system-*-reference`, `system-reference-*`, and `system-colored-purchase-flow` cases cover
requirements, entities, APIs, material updates, productive silence, and explicit diagram styling.
They use a synthetic course-store scenario, not private session content.

Two fresh-context host subagents read the baseline/revised system-design skill and production speak
guidance respectively, then simulated the same six scenarios as a group. Criteria were not supplied.
The baseline returned `detail: null` for all four reference scenarios; the revised probe supplied
grouped requirements, proposed entities, proposed APIs, and updated confirmed requirements. Both
stayed silent on productive progress. The baseline architecture diagram had no styles; the revised
one included amber purchase edges and purple confirmation-path edges, with explicit operation labels.

These grouped host probes are development evidence, not six independent production conversations or
a reliability estimate. They do not exercise production prompt composition, streaming, or panel
rendering. The revised API reference used an eight-row, three-column table; actual interview usability
and panel density still require a live session. The runtime Gate separately checks packaging and
existing rendering behavior; it does not score these semantic fixtures.

## Connected overview and focused-flow probes

The three `system-focused-download-sketch`, `system-overview-scope-coverage`, and
`customer-focused-approved-flow` fixtures check connected architecture, scope coverage, and focused
views that retain required gates. These are synthetic development cases, not private session records.

A fresh-context host subagent read the baseline skills and returned three grouped responses; another
read the revised skills and answered the same synthetic download, initial-overview and routine-reply
scenarios. Pass criteria were hidden. Baseline download retained both the temporary-link return and
an unrelated launch check; revised download used five forward connections and put returned links in
text. Baseline overview had eight boxes and twelve arrows; revised overview grouped responsibilities
into six boxes, covering library, launch and updates and marking unresolved behavior open. Baseline
RRK retained reciprocal extraction/evidence returns and a manual branch; revised RRK omitted those
and preserved required approval before send. It retained an explicit send-outcome audit write, which
is a state-changing operation rather than ordinary response data.

These are one grouped sample per revision, not five independent repetitions, production-provider
runs or a reliability estimate. They used full skill text but not the production coach prompt/tool
loop. The probes establish an observed shape change, not guaranteed coaching quality; the fixture
protocol above remains the production evaluation procedure. Gate checks catalog packaging and code,
not these semantic outcomes. Rendering and visual checks are reported separately.
