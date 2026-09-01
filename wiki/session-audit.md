# Session Evidence

> The one bounded stack every optional record a live session produces travels on, built to the
> [lean coaching core](./lean-coaching-core.md) contract: evidence is useful after an incident, and
> it must never decide whether Jarvis hears, reasons, captures, or delivers a tip.

## Why It Exists

A live session produces four kinds of optional record: the human coaching story, the evaluator's
attempt provenance, what crossed the provider boundary, and agent-facing diagnostics. Their content
differs; their product contract does not. So they share one transport, one worker, one per-session
handle, one close lifecycle, one health record, and one uniform best-effort loss contract — rather
than four queues that can each starve, stall, or lie independently.

## One Event, Two Projections

Every occurrence becomes one versioned
[`SessionEvent`](../Sources/JarvisCore/Diagnostics/SessionEvent.swift): a stable kind, session and
attempt attribution where applicable, occurrence and record timing, and typed detail. One occurrence
produces one event; nothing is mirrored into a second call or a second stack.

Producers keep narrow typed views —
[`BrainTrafficAuditing`](../Sources/JarvisCore/Diagnostics/BrainTrafficAuditing.swift),
[`CoachingAttemptAuditing`](../Sources/JarvisCore/Diagnostics/CoachingAttemptAuditing.swift), and
[`ActivityEventRecording`](../Sources/JarvisCore/Diagnostics/ActivityEventRecording.swift) — plus the
free `jlog` function for diagnostics. All of them converge on one per-session
[`FileSessionAudit`](../Sources/JarvisCore/Diagnostics/FileSessionAudit.swift) handle. Focused tests
and callers without a session pass `nil`; there is no disabled implementation, because absence
already means "do not record."

Two projections read that one stack:

| Projection | What it shows |
|---|---|
| The **Activity window** ([`ActivityLog`](../Sources/JarvisCore/Diagnostics/ActivityLog.swift)) | The high-level human story, drawn from the closed [`ActivityEvent`](../Sources/JarvisCore/Diagnostics/ActivityEvent.swift) presentation set |
| The **owner-only session folder** | The detailed record an agent or evaluator inspects: provider traffic, attempt provenance, and `jarvis-debug.log` |

The closed presentation set is what keeps transport, retry, timing, lifecycle, and raw-error detail
out of the human view. Sharing one stack grants no producer a path to author free-form human copy.

Provider traffic is kept at the wire level, the exact request and response bodies with images
redacted, rather than as provider-neutral messages: cache-busting prefix changes and tool-schema
bloat, the audit's main quarry, are visible only in the bytes actually sent.

## Contract

- Producers submit typed values to one process-level bounded worker. Timestamp rendering, JSON
  parsing, image redaction, serialization, Console emission, and file I/O happen only on that worker.
- Admission holds a short memory-only lock. It never performs parsing or I/O while holding it.
- Only the configured record-count or retained-byte limit drops a record. That loss increments a
  sticky health counter; later records still get an independent chance to enter the queue.
- Open, serialization, and write failures mark the affected evidence partial. Later records continue
  where the filesystem permits, so one failure does not disable the rest of the session's evidence.
- **No category has priority or reserved capacity.** A diagnostics-heavy session under pressure can
  lose audit records, and an Activity row can be lost like anything else. That is the approved
  degradation, not a bug to design around.
- Evidence failure cannot change the coach result, provider route, Activity event, or overlay. The
  coaching parity harness proves it: absent, enabled, blocked, full, oversize, and failing evidence
  produce identical provider calls, route transitions, terminal outcomes, and overlay output.

`audit-health.json` has one monotonic state:

| State | Meaning |
|---|---|
| `in_progress` | The session did not reach a controlled final write. Evidence is incomplete. |
| `complete` | The session closed with no known record loss. This state is terminal. |
| `partial` | The session closed but cannot certify complete evidence. This state is terminal. |

The evaluator treats `complete` totals as exact. It treats `partial`, `in_progress`, a missing marker,
or malformed records as incomplete evidence and labels surviving values as lower bounds or
unavailable. Historical sessions without versioned evidence keep their legacy interpretation.

The same record is what the human sees: a session that lost evidence reads as an **incomplete record**
in the Activity window, live and when browsed in history. A session whose marker cannot be read at all
shows nothing — unknown is not the same claim as incomplete.

## Lifecycle

One Start creates one owner-only session directory and one evidence handle in it. Regular Stop
cancels that session's producer tasks, waits for them in a background task, then closes the handle.
A new Start after Stop uses a new directory immediately; it does not wait for the old one. Activity
protects and declines to evaluate only the session that is still closing.

Close seals the handle, processes its already accepted records, and writes exactly one terminal
state. After that write, the evidence and its saved reports never change. A record submitted after
sealing is refused: a diagnostic falls back to the asynchronous process log, and nothing reopens or
corrects a sealed session.

Application Quit cancels live work, seals, makes a best-effort partial close request, and returns
immediately. It never waits on persistence, so a fast Quit can lose the last rows — including the
session-end Activity row — and leave `in_progress`, which already tells both the evaluator and the
human that the evidence is incomplete.

## Attribution

Every event is stamped with its session handle's identity at admission, so late work from a closing
session can never be attributed to its replacement. That applies to both projections: the files are
addressed by the originating session's directory, and the Activity window is scoped by the same
identity, so a stopped session's still-queued rows and its background close cannot reach the window
of the session that replaced it. A row that outlives its own window is lost from history and marks
its session partial rather than surfacing somewhere it does not belong.

Diagnostics follow the same rule: while a handle
is attached, `jlog` lines are that session's; with no attachment, or once the attached handle is
sealed, they reach the asynchronous process log only. A diagnostic is never guessed into whichever
session happens to be newest — a mis-attributed diagnostic is worse evidence than a missing one.

## Privacy and Verification

Evidence stays in the owner-only session directory under the existing retention policy. Request
images are redacted from traffic JSON because captured pixels already exist as owner-only screenshot
files there. Screenshot attachments for Activity are written owner-only inside that same directory,
before the row that references them. Nothing archives raw microphone audio or a separate live
transcript, and the capture heartbeat carries content-free frame progress only.

The implementation lives in `Sources/JarvisCore/Diagnostics/`; focused isolation tests cover bounded
admission, continued recording after one loss, persistence failures, immutable close, independent
Stop-to-Start lifecycle, and the incomplete-record notice. The repository gate is
`swift build && ./scripts/run-tests.sh`.
