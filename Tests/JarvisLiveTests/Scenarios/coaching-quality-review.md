# Coaching-quality instruction regression cases

`coaching-quality.json` contains synthetic inputs and semantic pass criteria for performance
reasoning, adaptive verification, comprehension, bounded delegation, and distinguishing tests.
It also includes ordinary-coding and system-design controls. No private session material is needed.

Run each input in a fresh model conversation with the production `JarvisPrompts.Coach.system`
base instructions, `speakTool(detailEnabled: true)` guidance, and the named bundled skill bodies
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
