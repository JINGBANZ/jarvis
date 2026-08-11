# Session Audit

> The diagnostics component that records what coaching attempted and what each brain provider saw,
> without making diagnostic persistence part of coaching latency or claiming incomplete evidence is
> exact. Activity remains the human-facing session record; raw runtime diagnosis remains in
> `jarvis-debug.log`.

## Purpose and Boundary

The session audit exists to answer questions the user-visible Activity feed cannot: which finalized
lines caused an attempt, which lines the substance gate included, whether a provider call was an
initial request or a screen continuation, and what was actually sent over the provider boundary. It
does not make coaching decisions, retry providers, or report failures to the user.

| Record | Audience | Contains |
|---|---|---|
| Activity | User | Heard speech, requested hints, screen actions, tips, deliberate silence, fixed failures, and session end |
| Session audit | Evaluator and developer | Attempt provenance, redacted provider traffic, and evidence completeness |
| `jarvis-debug.log` | Developer | Lifecycle, transport, timing, retry, and raw diagnostic detail |

Execution code sees only the optional
[`BrainTrafficAuditing`](../Sources/JarvisCore/Diagnostics/BrainTrafficAuditing.swift) and
[`CoachingAttemptAuditing`](../Sources/JarvisCore/Diagnostics/CoachingAttemptAuditing.swift) ports.
A persisted live session supplies one
[`FileSessionAudit`](../Sources/JarvisCore/Diagnostics/FileSessionAudit.swift) through both ports;
focused tests and callers without a session pass `nil`. There is no disabled implementation because
absence already means “do not audit.”

## Data Flow

```text
CoachDriver ── typed attempt events ───────┐
                                           ├─► FileSessionAudit ─► bounded worker ─► session files
Brain clients ── typed traffic events ────┘                              │
                                                                          ▼
                                                             completeness-aware evaluator
```

Provider and coach callbacks submit typed `Sendable` values. Admission is best-effort and never
waits for parsing, image redaction, JSON serialization, or file I/O. One process-level
[`SessionAuditWorker`](../Sources/JarvisCore/Diagnostics/SessionAuditWorker.swift) owns that work and
orders every accepted event across session handles while retaining only a bounded amount of data;
the exact limits remain source-owned in that type. If a lifecycle close cannot enter the full ring,
it retains an accepted-envelope watermark and runs immediately after those predecessors, before
traffic admitted later for a replacement session. Prioritized closes have their own fixed count
bound. A rejected close whose session has no unfinished worker envelope settles immediately against
its already-stable non-complete state; if the prioritized table is full, one fallback is coalesced
onto a session already represented by the bounded ring and released with that session's last envelope.

The worker writes the traffic, coaching-attempt, and health artifacts named by `FileSessionAudit` in
the same owner-only session directory as Activity and the screenshots deliberately shown to the
brain. [`SessionAuditEvidence`](../Sources/JarvisCore/Diagnostics/SessionAuditEvidence.swift) reads
the health artifact and decides whether evaluator totals are exact, lower bounds, or unavailable.
Historical sessions without the versioned marker retain their explicit legacy interpretation.

## Lifecycle

One Start creates one audit handle and passes its narrow observer views to that session's
`CoachDriver` and brain clients. A quick Stop → Start clears the old app-owned handle before creating
the replacement, so work still unwinding from the old session cannot contaminate the new directory.
The app's path registry keeps the handle weak, but retains its lock-protected settlement bit until the
worker reports the last mutation finished. Releasing the final producer therefore cannot make an
in-progress late correction look available or allow pruning to delete the directory it still touches.

| Transition | Behavior |
|---|---|
| Regular Stop or runtime teardown | Cancel active turns, wait for their final audit admissions asynchronously, then close the old audit under its deadline. A replacement Start does not wait. Once coaching work ends, only that session's Evaluate/Open report actions remain unavailable until its worker establishes a trustworthy final state. |
| Application Quit | Ask AppKit to defer termination and cancel active turns without blocking the main actor. If the bounded turn drain expires, audits whose close never began keep their deliberately partial open marker. Any close that did begin must settle or invalidate its marker before Jarvis approves process exit; drained audits are closed before replying. |
| Evaluate | Read the selected stopped session only when its own persistence gate is settled; interpret the health marker before presenting deterministic totals. Other settled history remains usable while an unrelated session is unavailable. |

Closing seals the session against later events, drains events already ahead of the close envelope,
and durably replaces the health marker before reporting success. The filesystem edge prepares the
replacement privately, then checks the close deadline and current health immediately before and
after its atomic rename. If preparation or the rename crosses the deadline, the worker replaces the
candidate with partial evidence. If that correction fails, it removes the rejected marker so the
evaluator sees a missing completion marker instead of stale “complete” evidence. Application Quit
uses this same asynchronous close while AppKit holds termination, so main-actor cleanup can continue.
It may abandon a close that never started after the bounded turn drain, leaving its open marker, but
never approves exit while an already-started close can still expose a marker awaiting correction.

The close deadline bounds how long its caller waits for a complete result; it cannot stop a filesystem
operation already in progress. A separate settlement signal fires only after the serial worker has
finished the final or corrective marker write, or has safely invalidated a rejected marker. If even
invalidation fails, settlement remains pending and Evaluate stays unavailable rather than trusting
ambiguous evidence. Regular Stop retains that settlement task until the session directory is safe
to read. Clear history and automatic pruning preserve every directory with a live audit handle and
every independently tracked unsettled mutation, including a settled handle that a delayed producer
could reopen, so a worker can never race deletion. Quit also awaits this gate for the current audit
and every earlier Stop whose close already began.

A callback rejected after sealing increments `late_event` and immediately reopens that session's
persistence gate. The worker schedules at most one serial correction to invalidate any already
published complete marker. A successful partial close can satisfy the same correction; if neither a
partial marker nor invalidation becomes durable, only that session stays unavailable. Reopening the
gate also cancels an evaluator reading that session and removes its derived transcript, Markdown
report, and HTML view. Once correction settles, the user can run a fresh evaluation over the new
partial-evidence state; an unrelated session's evaluator and saved report remain intact. Each saved
report carries the exact health-evidence stamp it read, so a separate evaluator that finishes after
the correction cannot republish a stale report as current.

## Failure Semantics

Audit persistence is deliberately weaker than coaching:

- Lock contention, queue pressure, and oversize events drop audit evidence immediately rather than
  delaying provider handling or overlay delivery.
- An open, write, or serialization failure disables further persistence for that session instead of
  repeatedly exercising a broken edge.
- A late event or close deadline miss makes evidence partial. A post-seal event also invalidates an
  earlier complete marker before the session becomes evaluable again.
- A failed corrective health write removes the rejected marker; new-format records without that
  marker are partial. If the marker cannot be removed, the session remains unevaluable.
- The health marker records the surviving failure facts when the filesystem is still usable, and
  the evaluator labels affected totals as lower bounds rather than silently treating missing records
  as zero.

There is no retry or backpressure path from the audit worker into coaching. This makes the failure
direction one-way: coaching produces optional evidence, while evidence persistence cannot change the
coach outcome, provider route, Activity event, or overlay.

## Privacy and Ownership

The audit follows the session directory's owner-only permissions and retention policy documented in
[sandbox.md](./sandbox.md). Request images are redacted from traffic JSON because the deliberately
captured pixels already live as owner-only screenshot files in that directory. Raw microphone audio
and a separate live-transcript archive are never created for the audit.

The evaluator remains read-only over the completed session directory and source checkout. It uses
the persisted attempt identity to join provenance and provider traffic instead of inferring causality
from prose, `stay_silent`, or Activity copy.

## Code Map and Verification

| Area | Source |
|---|---|
| Optional execution ports and typed events | `BrainTrafficAuditing.swift`, `CoachingAttemptAuditing.swift`, `BrainTrafficAuditEvent.swift`, `CoachingAttemptAuditEvent.swift` |
| Session handle and lifecycle | `FileSessionAudit.swift`, `SessionAuditLifecycle.swift` |
| Bounded admission, encoding, and failure containment | `SessionAuditWorker.swift` |
| Owner-only filesystem edge | `SessionAuditFileWriter.swift`, `SessionAuditWriting.swift` |
| Evaluator completeness interpretation | `SessionAuditEvidence.swift`, `EvaluationTranscript.swift`, `SessionMetrics.swift`, `TriggerQualityMetrics.swift` |

Deterministic parked and failing writers exercise overload, blocked I/O, deadline crossing, open and
write failure, serialization failure, both final-commit deadline crossings, failed correction
invalidation, post-close marker correction, bounded rejected-close retention, protected-session
retention, and behavioral equivalence in
[`SessionAuditIsolationTests`](../Tests/JarvisCoreTests/Diagnostics/SessionAuditIsolationTests.swift).
The repository gate remains `swift build && ./scripts/run-tests.sh`.
