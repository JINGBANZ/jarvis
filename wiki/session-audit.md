# Session Audit

> A diagnostics component that records coaching-attempt provenance and provider traffic without
> making persistence part of coaching behavior or latency.

## Why It Exists

Activity is the user-facing coaching history. `jarvis-debug.log` contains runtime diagnosis. The
session audit exists for the evaluator and developer: it records which finalized transcript lines
caused an attempt, which lines reached the brain, and what crossed the provider boundary.

Execution code receives only the optional
[`BrainTrafficAuditing`](../Sources/JarvisCore/Diagnostics/BrainTrafficAuditing.swift) and
[`CoachingAttemptAuditing`](../Sources/JarvisCore/Diagnostics/CoachingAttemptAuditing.swift) ports.
A live persisted session supplies one
[`FileSessionAudit`](../Sources/JarvisCore/Diagnostics/FileSessionAudit.swift); focused tests and
callers without a session pass `nil`. There is no disabled implementation because absence already
means "do not audit."

## Contract

- Producers submit typed values to one process-level bounded worker. JSON parsing, image redaction,
  serialization, and file I/O happen only on that worker.
- Admission holds a short memory-only lock. It never performs parsing or file I/O while holding it.
- Only the configured record-count or retained-byte limit drops a record. That loss increments a
  sticky health counter; later records still get an independent chance to enter the queue.
- Open, serialization, and write failures mark the affected evidence partial. Later records continue
  where the filesystem permits, so one failure does not disable the rest of the session audit.
- Audit failure cannot change the coach result, provider route, Activity event, or overlay.

`audit-health.json` has one monotonic state:

| State | Meaning |
|---|---|
| `in_progress` | The session did not reach a controlled final audit write. Evidence is incomplete. |
| `complete` | The audit closed with no known record loss. This state is terminal. |
| `partial` | The audit closed but cannot certify complete evidence. This state is terminal. |

The evaluator treats `complete` totals as exact. It treats `partial`, `in_progress`, a missing marker,
or malformed records as incomplete evidence and labels surviving values as lower bounds or
unavailable. Historical sessions without versioned audit evidence keep their legacy interpretation.

## Lifecycle

One Start creates one audit and one owner-only session directory. Regular Stop cancels that session's
producer tasks, waits for them in a background task, then closes the old audit. A replacement Start
uses a new directory immediately; it does not wait for the old audit. Activity protects and does not
evaluate only the session that is still closing.

Close seals the audit, processes its already accepted records, and writes exactly one terminal state.
After that write, the audit and its saved reports never change. A callback after sealing is a lifecycle
defect: the worker rejects it and writes a debug message; it does not reopen or correct the audit.

Application Quit cancels live work, seals the audit, makes a best-effort partial close request, and
returns immediately. It never waits on audit persistence. A crash or fast Quit can therefore leave
`in_progress`, which already tells the evaluator that the evidence is incomplete.

## Privacy and Verification

The audit stays in the owner-only session directory under the existing retention policy. Request
images are redacted from traffic JSON because captured pixels already exist as owner-only screenshot
files there. It never archives raw microphone audio or a separate live transcript.

The implementation lives in `Sources/JarvisCore/Diagnostics/`; focused isolation tests cover bounded
admission, continued recording after one loss, persistence failures, immutable close, and independent
Stop-to-Start lifecycle. The repository gate is `swift build && ./scripts/run-tests.sh`.
