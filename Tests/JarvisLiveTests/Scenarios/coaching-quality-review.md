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

## Clear cues, notes, and walkthroughs: development regressions (2026-09-30)

The new synthetic cases cover following valid discovery, compact factual notes, the explicit
`Walk one case through` step, unfamiliar questions, source validity, stopping, completed walkthroughs,
interviewer redirects, conversation language, missing obligations, pilot source coverage, unsupported
thresholds and supported fact/risk accents. They contain no private practice transcript or customer data.
A cue defaults to null detail; optional explanation is at most two short supporting bullets. Notes,
diagrams and explicitly requested scripts have their own shapes. Notes are distinct from a two-fact
playback: `What we know so far` has 3–4 short bullets covering goal, bottleneck, constraints and the
open question, preserving decision-relevant numbers and distinguishing unknowns from facts.

One fresh baseline subagent read the bundled skill and relevant coaching prompt instructions, then
answered six independent synthetic inputs in one conversation, without pass criteria. The baseline
skill's whole-file SHA-256 was
`9eb01434821927efb50e7098e3edc26a35c9d96800c6fed34e4e7bc739223730`.
It used the inherited Codex host model; the exact provider snapshot was not exposed. These are
instruction-level development observations with surrounding host instructions, not production-provider
runs, fresh-per-case samples, signed-app evidence or a reliability estimate.

| Related fixture | Baseline observation |
|---|---|
| `customer-own-discovery-flow` | Pass: chose silence while the candidate pursued the current workflow after earlier cost-question nudges. |
| `customer-notes-full-state` | Fail: two bullets captured the comparison bottleneck and no automated chasing, but omitted 80 requests/week, manager approval above $4,000 and the unknown routine/missing-information split. |
| `customer-sketch-to-walkthrough` | Fail: gave a short cue about a $5,000 request but no distinct walkthrough step label after the drawing was complete. |
| `customer-unfamiliar-reconciliation` | Pass: concise explanation of reconciliation and the question. |
| `customer-source-context-not-validity` | Pass: different operating contexts do not prove both claims valid. |
| `customer-stop-practice` | Pass: acknowledged stopping without continuing the exercise. |

These fixture inputs make context self-contained and sharpen individual criteria; they are related
to the baseline prompts, not identical controlled before/after pairs. Existing passes are controls,
not evidence that the edit improved those behaviors. The new completion and redirect cases distinguish
actual candidate work from earlier coaching reminders: a drawing or a suggestion is not a walkthrough,
a completed walkthrough is not repeated, and interviewer steering is followed without another nag.
Technical cases reject false certainty: valid extraction is not a valid source, unseen obligations
cannot be recovered by assertion, narrow pilots still need validated source coverage, and proposed
numbers do not prove safety. Accents must contain a supported full phrase inside at most 1–2 short
`**Key fact: ...**` or `**Risk: ...**` spans; unverified guesses are not key facts.

Revised skill whole-file SHA-256:
`fda93677e777bc41e645870752260fac7648141215eb2e2814bc8470dd8dfd3a`.
One separate fresh-context agent read the production coach base, speak guidance and this revision,
then answered all 14 committed inputs in one conversation without their pass criteria. It used the
inherited Codex host model (exact provider snapshot unavailable) and returned JSON coach actions.
Each scenario was treated independently, but these were not fresh conversations per case. The
following judgments concern the new semantic criteria, not every generic line-length constraint.

| Fixture | Revised observation |
|---|---|
| `customer-own-discovery-flow` | Pass: chose `stay_silent` during the candidate's valid discovery flow. |
| `customer-notes-full-state` | Pass: four bullets under “What we know so far” retained 80 requests/week, the comparison bottleneck, $4,000 approval, six-week pilot, email exclusion and unknown volume split. |
| `customer-sketch-to-walkthrough` | Pass: “Next step: Walk one case through”; a hypothetical $5,000 Request A retains manager approval and manual missing commitments. |
| `customer-unfamiliar-reconciliation` | Pass: “Reconciliation means comparing records and resolving differences”; matching alone does not establish safe delivery commitments. Two short detail bullets support the explanation. |
| `customer-source-context-not-validity` | Pass: “Different conditions may explain disagreement; they do not prove validity.” |
| `customer-stop-practice` | Pass: “Okay, stopping practice.” Detail is null; no continuation. |
| `customer-walkthrough-completed` | Pass: moves to a risk-driven deep dive on approval enforcement or conflicting terms without repeating the case. |
| `customer-interviewer-redirect` | Pass: follows the security question with code-enforced manager approval bound to the exact purchase version and authorized manager. |
| `customer-conversation-language` | Pass: explains in Spanish, including “Si falta la fecha, el equipo la revisa manualmente,” and retains human approval. |
| `customer-missing-document-obligations` | Pass: “validating extracted fields cannot establish missing obligations”; obtain authoritative sources/rules and leave unresolved gaps manual. |
| `customer-narrow-pilot-source-coverage` | Pass: “fewer customers do not fix missing source coverage”; verify authoritative obligations before relying on reports. |
| `customer-invented-threshold-not-proof` | Pass: “proposed targets, not evidence of safety”; representative held-out cases, customer-agreed error limits and calibrated confidence are needed. |
| `customer-highlight-confirmed-facts` | Pass: one cue with `**Key fact: Manager approval is required above $4,000.**` as the sole detail bullet. |
| `customer-highlight-guess-control` | Pass: “Keep 90% as an unverified hypothesis, not a key fact”; inspect real requests rather than inventing support. |

These single-pass instruction-level probes are development evidence, not production-provider runs,
held-out transfer evidence or a reliability rate. The baseline and revised inputs are related, not
identical controlled pairs. The other existing fixtures were not rerun semantically. Rendering was
checked separately with synthetic previews and automated layout/formatting tests; no signed-app
coaching session was run for this revision.

After the probes, the rollout heading “Shadow” became “In shadow mode” to retain the existing catalog
smoke assertion's lowercase term; no behavioral instruction changed. This final wording was checked
by inspection, not another semantic run. Final whole-file SHA-256:
`afd425e3fdc0cb249dbfd24f24bfdcb8a03f95e34db879106d33ddf6963ab534`.
Its trimmed body is 14,965 UTF-8 bytes; the 15,000-byte catalog assertion is unchanged. The repository
Gate remains separate packaging/code evidence and does not deploy the skill into a running app.
