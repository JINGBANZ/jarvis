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
