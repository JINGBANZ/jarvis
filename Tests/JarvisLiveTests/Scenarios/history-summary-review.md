# History-summary regression cases

These synthetic cases exercise factual compaction independently of capture, transcription, and
provider routing. In a fresh conversation, send the production `JarvisPrompts.HistorySummary.system`
as the system instruction and JSON-encode only a case's `input` as the user message. Do not send
its `pass` rubric to the model. Use the configured summary model without tools and preserve its
identity, response, and prompt revision locally.

First validate the five-field briefing shape with the production validator. A single whole-response
JSON Markdown fence is accepted; surrounding prose, truncated JSON, missing fields, and incorrect
field types are rejected. Structural validity does not establish factual accuracy: review the output
against the case's complete semantic `pass` criterion. Mark omitted evidence separately from invented
facts, and do not score solely by keyword matches. Repeat uncertain or failing cases; a single sample
is not a reliability rate. Test accepted and rejected replacement behavior with the Core compaction
tests separately.

The initial four-case Claude CLI check (`claude-haiku-4-5-20251001`) preserved the central invariants, advice, and attribution,
without answering historical requests. All four responses used JSON fences, motivating the narrowly
scoped envelope handling. The deque case omitted the explicit absence of performance test output;
it did not invent successful tests. Screenshot questions remained as unknowns in some briefings.
These observations are instruction-level evidence, not a live-session quality guarantee.
