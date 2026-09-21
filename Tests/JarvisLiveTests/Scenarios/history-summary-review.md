# History-summary regression cases

These synthetic cases exercise factual compaction independently of capture, transcription, and
provider routing. In a fresh conversation, send the production `JarvisPrompts.HistorySummary.system`
as the system instruction and JSON-encode only a case's `input` as the user message. Do not send
its `pass` rubric to the model. Use the configured summary model without tools and preserve its
identity, response, and prompt revision locally.

First validate the five-field briefing shape with the production validator. A single whole-response
Markdown fence is accepted when untagged or tagged `json` case-insensitively, with LF or CRLF line
endings; surrounding prose, other language tags, incomplete fences, truncated JSON, missing fields,
and incorrect field types are rejected. Structural validity does not establish factual accuracy or detect a refusal inside valid JSON: review the output
against the case's complete semantic `pass` criterion. Mark omitted evidence separately from invented
facts, and do not score solely by keyword matches. Repeat uncertain or failing cases; a single sample
is not a reliability rate. Test accepted and rejected replacement behavior with the Core compaction
tests separately.
