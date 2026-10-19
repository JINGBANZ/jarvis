# History-compaction content review

Run `./scripts/run-live-tests.sh H`. C35 verifies that the first real summary is accepted under the
token budget and reduces history size. C36 verifies that the recall request carries condensed
history with the queue decision and delivers a reply. These checks do not establish factual quality.

Read the final spoken step's actual transcript first: it must ask which message-broker technology
was chosen for Project Cedar. If that meaning was lost, record recall as not observed and identify
the transcription gap before assessing the coach. The English-only scenario declares English as
recognition guidance; that setting alone does not prove accurate transcription.

Read the first summarizer exchange and the final spoken step's request and reply in the owner-only
session evidence. Confirm the summarized prefix contains the planted facts; later messages must not
be the only source of the answer. Judge meaning rather than exact wording:

- The queue decision is Kafka for Project Cedar.
- The window includes an event exactly ten seconds old; the cutoff is inclusive.
- Tests have not run. The code remains a proposal, without observed execution or benchmark results.
- Resolved naming, dashboard, documentation, and example choices can be shortened or omitted. They
  must not replace or contradict the active decisions and verification limits.
- The final reply recalls the queue and boundary correctly and says what is still unverified.
  It must not invent a successful test run or treat a design discussion as proof of correctness.

Record this review separately from the automated results. The Core tests cover invalid, unfinished,
stale, and cancelled output, retained tool/skill pairs, and coaching while the summarizer is parked;
this real-provider scenario does not force those rare outcomes.
