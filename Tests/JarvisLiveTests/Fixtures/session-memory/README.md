# Synthetic session-memory assay

Run from the repository root:

```sh
python3 scripts/eval-session-memory.py --run memory-evaluation-001
```

The harness creates a private artifact directory and builds the Swift bridge before any model call.
A failed build stops the run and leaves its diagnostic log. Later bridge exchanges use that freshly
built test binary. Run the no-model harness checks with `python3 -B scripts/test_eval_session_memory.py`.

This explicitly invokes the locally authenticated Claude CLI. It makes 54 serial model calls:
three synthetic domains × two independent repetitions × three rounds × (one summary + two
follow-ups). The default requested model is `haiku`; each response records actual `modelUsage`.
Tools and session persistence are disabled. It does not use private session input. Artifacts live
in a new owner-only workspace `.jarvis/` directory and must not be committed.

The frozen `cases.json` contains genuinely new history in each round and six prewritten expected
facts per question. Freeze the fixture and checklist before generation; do not tune either against
outputs. The run copies the fixture and records SHA-256 hashes, source HEAD, actual prompt text,
model identity, all selected prefixes/tails, and responses. Questions and expected facts never go
to the summarizer. Expected facts never go to the follow-up model.

The opt-in Swift test bridge uses the production `CoachHistory` prefix selection, pair retention,
compaction, token estimator, and `HistorySummary` prompt/input/validator. It forces three rounds
without waiting for the production 10,000-estimated-token trigger, using the normal 0.6 prefix
fraction. Histories are intentionally smaller than real long sessions. Invalid or failed summaries
are failures and preserve the previous history; they are never fed forward as valid briefings.
Normal offline Gate runs do not invoke a model. The bridge requires the explicit environment variable
set by the Python harness.

After each compaction, the same model receives a question with either full history or the evolving
compacted history. The remaining recent tail is identical and asserted in both conditions. Order
alternates by repetition, round, and case, so each matched question occurs in both orders across
repetitions. Follow-up answers are not appended to either history. This is a CLI instruction-level
recall assay, not the live coach tool loop, transport, production 2048-output-token limit, or proof
of coaching quality. CLI scaffolding and token accounting differ from the app. Two repetitions are
small descriptive samples, not calibrated error-rate estimates.

## Scoring before interpreting results

A reviewer scores semantic entailment, not substring overlap. For every fixed fact at each round,
label its source location: selected prefix only, recent tail, both, or absent from the current
compacted input because of an earlier omission. Score briefing retention only for established,
still-relevant facts present in the selected prefix; facts available only in the tail are not
briefing successes. Track earlier omissions separately across rounds, including their first loss.
For later-round facts updating earlier ones, score the current status, not stale superseded values.

Use these mutually exclusive fact outcomes: retained accurately; omitted; contradicted; or
attribution/uncertainty error (for example claimed tests converted into observed tests). Inventory
additional unsupported claims separately as inventions, even when no checklist item covers them.
A fact already lost before this round remains a cumulative loss; do not inflate the new round's
prefix-retention denominator with unavailable facts. Keep raw evidence quotations with each score.

Score both follow-ups against the whole corresponding source history and fixed expected facts.
A correct guess in an answer does not repair a briefing omission. Report full and compacted
accuracy, paired differences, abstentions, contradictions, attribution errors, inventions, and
invalid-summary/preserve-history events, broken down by domain and round. Have a second reviewer
adjudicate ambiguous entailment. Do not use structural validation as evidence of semantic accuracy.

Report context bytes separately from the actual production estimated-token counts before/after
compaction; neither is a measured provider token saving. Follow-up provider usage includes CLI
scaffolding. Record serial CLI wall latency and provider API latency separately, with medians/ranges
for summaries and paired follow-ups. No latency result here estimates the signed app's critical path.
