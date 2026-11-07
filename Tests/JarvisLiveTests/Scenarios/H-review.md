# History-compaction content review

Run `./scripts/run-live-tests.sh H`. C35 verifies that the first real summary is accepted and reduces
history size, with no hard summary-token ceiling. C36 verifies that condensed history preserves the
initial queue decision before its replacement, the recall request carries the newer decision, and a
reply is delivered. These checks do not establish factual quality.

Read the first summarizer exchange and the final spoken step's request and reply in the owner-only
session evidence. Confirm the summarized prefix contains the planted facts; later messages must not
be the only source of the answer. Judge meaning rather than exact wording:

- The first summary preserves Kafka as the queue for Project Cedar at that earlier point.
- The later update replaces Kafka with SQS. The final reply says SQS is current; any mention of
  Kafka identifies it as superseded. A later summary may omit Kafka when its rationale is no longer
  useful, but must preserve the current decision.
- The window includes an event exactly ten seconds old; the cutoff is inclusive.
- Project Cedar remains a proposal without execution, tests, or benchmarks.
- The separate Java binary-search exercise is still open. Version A's passing tests were reported
  by the user, not observed by Jarvis. Version B changed the boundary comparison and has not been
  retested. The earlier success proves neither version B nor Project Cedar; each topic retains its
  own decisions and evidence limits.
- Resolved naming, dashboard, documentation, and example choices can be shortened or omitted. They
  must not replace or contradict the active decisions and verification limits.
- The final reply recalls the current queue, unchanged boundary, and Java version B's unverified
  status. It must not invent a successful test run or treat a design discussion as proof of correctness.

Record this review separately from the automated results. The Core tests cover invalid, unfinished,
stale, cancelled, and nonshrinking output, suppression of repeated unchanged candidates, retained
tool/skill pairs, and coaching while the summarizer is parked;
this real-provider scenario does not force those rare outcomes.
