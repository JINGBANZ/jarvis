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
the exact limits remain source-owned in that type.

The worker writes the traffic, coaching-attempt, and health artifacts named by `FileSessionAudit` in
the same owner-only session directory as Activity and the screenshots deliberately shown to the
brain. [`SessionAuditEvidence`](../Sources/JarvisCore/Diagnostics/SessionAuditEvidence.swift) reads
the health artifact and decides whether evaluator totals are exact, lower bounds, or unavailable.
Historical sessions without the versioned marker retain their explicit legacy interpretation.

## Lifecycle

One Start creates one audit handle and passes its narrow observer views to that session's
`CoachDriver` and brain clients. A quick Stop → Start clears the old app-owned handle before creating
the replacement, so work still unwinding from the old session cannot contaminate the new directory.

| Transition | Behavior |
|---|---|
| Regular Stop or runtime teardown | Cancel active turns, wait for their final audit admissions asynchronously, then close the old audit under its deadline. A replacement Start does not wait. |
| Application Quit | Ask AppKit to defer termination, cancel active turns, and await a bounded drain without blocking the main actor. Include any audit still closing after an immediately preceding Stop, then close the current audit before replying that termination may continue; if work cannot drain, its open marker remains deliberately partial. |
| Evaluate | Read a stopped session only after its regular close finishes; interpret the health marker before presenting deterministic totals. |

Closing seals the session against later events, drains events already ahead of the close envelope,
and durably replaces the health marker before reporting success. The filesystem edge prepares the
replacement privately, then checks the close deadline and current health immediately before and
after its atomic rename. If preparation or the rename crosses the deadline, the worker replaces the
candidate with partial evidence. Application Quit uses this same asynchronous close while AppKit
holds termination, so main-actor cleanup can continue and the process does not exit early.

## Failure Semantics

Audit persistence is deliberately weaker than coaching:

- Lock contention, queue pressure, and oversize events drop audit evidence immediately rather than
  delaying provider handling or overlay delivery.
- An open, write, or serialization failure disables further persistence for that session instead of
  repeatedly exercising a broken edge.
- A late event or close deadline miss makes evidence partial.
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
write failure, serialization failure, both final-commit deadline crossings, and behavioral
equivalence in
[`SessionAuditIsolationTests`](../Tests/JarvisCoreTests/Diagnostics/SessionAuditIsolationTests.swift).
The repository gate remains `swift build && ./scripts/run-tests.sh`.
