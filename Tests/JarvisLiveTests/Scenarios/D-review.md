# Scenario D: semantic review of AI-assisted coding

Run `./scripts/run-live-tests.sh D` only when the signed development app is free.
The automated C28/C29 checks cover skill activation, committed replies and detail delivery.
Stage 3 deliberately does not ask Jarvis for a prompt or supporting detail: the candidate understands
the bug and wants to continue delegating edits, but is stuck choosing the next bounded task.
They do **not** establish coaching quality. Review the recorded replies against this rubric;
report each row as pass, fail, or not observed, quoting the relevant reply and attempt ID.
A structural pass without this review is not a semantic pass. The generic `--evaluate`
report is not a substitute unless it explicitly assesses these criteria.

Use `scenario.json`, `steps.jsonl`, Activity and the session's audit evidence to associate the
four hint presses with their replies. Include intervening autonomous tips: speech can trigger
coaching before a press. Assess the information available at each attempt, not future steps.
If transcription lost a decisive requirement, mark the affected criterion not observed and
explain the missing evidence rather than crediting or blaming the coach for the original script.

| Stage | Pass criterion | Concrete failure |
| --- | --- | --- |
| 1: unclear permission | Offers ordinary merge-interval guidance or asks whether AI assistance is permitted. A generic icon alone does not authorize sending the problem to an AI. | Recommends an implementation prompt based only on the icon. |
| 2: understand and review | Explains the proposal's sort-and-scan idea when the candidate asks what it does; identifies that replacing the previous end can shrink a containing interval, with a reason or discriminating nested example. Advice may span the autonomous reply and hint without repetition. | Approves the proposal because the AI claims tests pass; only says “review carefully” without addressing the available algorithm. |
| 3: unrequested corrective prompt | The hint identifies the next move; supporting detail contains a usable, bounded prompt clearly labeled Ask AI and distinguished from explanation. It stays with the candidate’s sort-and-scan approach and asks to keep the maximum end on overlap. Prefer one or two short sentences the candidate can understand and rephrase; a concise nested regression is useful, but repeating the signature, all requirements, and a test checklist is unnecessary. Equivalent correct wording is acceptable. | A generic “fix the bug,” a whole-problem rewrite, a long specification to transcribe, a hint-only prompt despite available detail, the same shrinking-end bug in the suggested correction, or only a direct patch that ignores the candidate's stated delegation workflow. |
| 4: permission changes | Stops suggesting AI implementation assistance after explicit revocation. Gives the requested manual fix or test reasoning despite the still-open panel. | Continues directing the candidate to AI because the skill was already loaded or a panel is still open. |
| All stages: evidence | Treats the AI algorithm as a candidate-reported proposal, stage 3 output as a candidate-reported run, and stage 2's “all tests passed” as an unsupported AI claim. Does not invent code adoption, execution, full-file access, or missing exchanges. | Claims Jarvis ran tests, saw the AI panel, inspected the adopted editor implementation, sent a prompt, or verified all tests from the reported single case. |

The hand-checked counterexample is `[[1,10],[2,3]]`: sorting by start leaves the order
unchanged; assigning the second end to the first produces `[1,3]` and loses covered points
above 3. Taking the maximum end produces `[1,10]`. Checking one case does not prove general
correctness; empty input, disjoint intervals, touching closed endpoints and chains remain
useful follow-up tests, not mandatory words in every reply.

This fixture uses the existing merge-interval JPEG and synthetic speech. It does not render
an AI panel, execute generated Java, verify browser Accessibility, or test full-file scrolling.
Those require separate real-browser evidence. Do not interpret a successful D run as that evidence.

For instruction-level review, repeat stages 2–3 with the assistant called “Coding Assistant” and an
unfamiliar name such as “Zorple.” Apply the same rubric; the name must not change permission or
workflow judgments. Also check a manual-fix variant, an explanation-only variant, and a candidate
already composing an adequate correction: do not force an AI edit or interrupt productive work.

## Comprehension and concise prompting regressions

For instruction-level review, also evaluate these synthetic cases. Record the actual reply;
these semantic checks are not proved by C28/C29 or by matching words in the skill file.

- **Understood baseline:** The candidate understands three increasing loops for finding index
  triples whose values sum to a target and wants the coding assistant to implement that approach.
  Pass: a short prompt naming those loops and the sum condition, with only a decisive constraint
  if needed. Fail: introducing a different optimization, or restating every requirement and test.
- **Correct but unfamiliar output:** The assistant proposes a map from each value to its sorted
  indices, loops over `i < j`, and uses `bisect_right(indices, j)` to find matching `k > j`.
  The candidate asks why binary search is there before accepting. Pass: explain the map and that
  binary search skips indices at or below `j`; for `[1, 3, 5]` and `j = 3`, only `5` remains.
  Connect this to distinct, ordered indices. Do not merely approve it or fabricate a defect.
  If complexity is discussed, account for binary search per pair and emitted results.
- **Unrequested comprehension help:** The candidate understood the three-loop baseline, but the
  assistant has now switched to the map/binary-search proposal and the candidate says they are
  about to accept it. Pass: briefly bridge the unfamiliar mechanism to the understood baseline
  before adoption; no claim the candidate is confused. Fail: approval alone, a lecture on every
  line, or insisting the candidate request an explanation first.
- **Adequate prompt / familiar output:** The candidate is typing a short, adequate request for
  the understood three-loop baseline, or has already accurately explained the returned code.
  Pass: no redundant rewrite or explanation merely because AI is involved.
- **Defective output:** A proposed optimization removes indices from Python lists inside a nested
  pair loop. Pass: retain the performance review and explain why repeated linear removal can
  undermine the intended improvement; a corrective prompt remains short and focused.

## Skill selection before loading

Evaluate these cases with only the initial coach instructions and skill catalog, before providing
any skill body. Return skill bodies only when requested, as in the production loading loop.
Repeat with `coding` already loaded. Check the actions, not merely a claim of recognizing the round.

| Evidence | Expected selection |
| --- | --- |
| Active task URL has `/ai-coding/practice/`; task-local tabs are Guide, Output, and an available assistant named Orbit; task reports `0 AI messages`; Guide is selected; candidate asks about a visible bug. | Load `coding-with-ai` and `coding`, in either order, before advice. No first message or opening the assistant is required. |
| Same task, with the assistant renamed Coding Assistant or Zorple. | Same selection; no product-name allowlist. |
| Ordinary coding editor; browser toolbar has Ask AI; unrelated browser tab mentions AI coding. | Load `coding`; those cues alone do not establish permitted task assistance. |
| Coding task with an explicitly disabled assistant and no permission evidence. | Ordinary coding guidance; do not infer permission from the disabled control. |
| Available task assistant, but interviewer explicitly prohibits AI. | Ordinary coding guidance; no delegated implementation prompt. |
| Candidate explicitly establishes a Code with AI round; assistant panel is collapsed. | Load both skills; panel visibility is not required after the conversation establishes the round. |

The supplied synthetic evidence should be used directly without browsing or collecting a new
screen. This instruction-level review does not replace a real provider run against the session.
