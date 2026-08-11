# Transcription Benchmark

> The explicit signed-app regression harness for Jarvis's transcription paths. It plays fixed
> synthetic speech through Jarvis's own process, measures what happened, and writes a repeatable
> result without opening the microphone or changing the Mac's network connectivity.

## Purpose and Boundary

The benchmark answers a narrow question: **given known audio, does each production transcription
path receive it continuously and return the expected result with a healthy lifecycle?** It uses the
real signed `Jarvis.app`, process-scoped system-audio capture, provider sessions, reconnect code, and
replay buffer. It does not start a coaching session or evaluate what the coach did.

The runner and scorer have different jobs:

```text
fixed synthetic speech
        │
        ▼
hidden signed Jarvis.app ── lifecycle + capture observations ──► deterministic scorer
        │                                                           │
        └──────── real transcription provider path ─────────────────┘
                                                                    ▼
                                                               summary.json
```

The app-side runner is the experiment. The Foundation-only scorer is the referee: it receives the
known phrase, ordered lifecycle events, timestamps, and content-free capture counters, then always
produces the same result for the same input. Keeping that calculation in
[`Sources/JarvisCore/Benchmark/`](../Sources/JarvisCore/Benchmark/) makes it unit-testable without
macOS permissions, audio hardware, or a provider connection. Capture, playback, and provider wiring
stay in [`Sources/JarvisApp/Benchmark/`](../Sources/JarvisApp/Benchmark/).

This is separate from session auditing:

| | Transcription benchmark | Session audit and evaluation |
|---|---|---|
| Question | Does known synthetic audio survive and transcribe correctly? | What happened during a real coaching session, and why? |
| Input | Fixed non-user audio and benchmark lifecycle events | User-visible Activity, coaching-attempt provenance, provider traffic, and screenshots |
| Invocation | Explicit developer command | Normal session persistence plus an explicit completed-session evaluation |
| Output location | `.jarvis/transcription-benchmarks/<run>/` | The matching `.jarvis/<session>/` directory |
| Code ownership | `JarvisCore/Benchmark` and `JarvisApp/Benchmark` | `JarvisCore/Diagnostics`, the coach/provider observer seams, and the app session lifecycle |

They share only the repository's owner-only `.jarvis/` privacy posture and the architectural rule
that deterministic logic belongs in Core. Benchmark scoring neither writes session-audit evidence
nor participates in coaching.

## Isolation From Normal Use

The normal app constructs transcription sessions without benchmark instrumentation. Its
[`TranscriptionSession`](../Sources/JarvisCore/Transcription/TranscriptionSession.swift) contract and
`AppDelegate` wiring expose no benchmark callback or transport-fault capability. Only
[`TranscriptionBenchmarkRunner`](../Sources/JarvisApp/Benchmark/TranscriptionBenchmarkRunner.swift)
supplies the optional
[`TranscriptionBenchmarkInstrumentation`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmarkInstrumentation.swift)
bundle.

When that bundle is absent:

- provider adapters do not construct or record benchmark events;
- no benchmark recorder, scorer, artifact writer, or session-audit integration exists;
- Realtime uses its direct production reconnect schedule, with no fault hold or polling; and
- Apple Speech keeps its normal finalized-result and continuity behavior.

The small optional probe points remain inside the provider adapters because readiness, endpoint,
commit, provider-final, reconciled-final, and replay evidence exists only at those private production
boundaries. The injected observer follows the same absence-means-disabled shape as the session-audit
ports, but it is a separate benchmark-owned contract. The reconnect controller likewise exists only
for an explicit reconnect run and owns the hold outside `RealtimeTranscriber`'s normal state.

## Running It

The launcher builds the signed app and opens a hidden benchmark mode so macOS attributes System Audio
Recording permission to the stable app identity. It is not a separate SwiftPM executable because the
experiment must exercise the same signed app, TCC identity, capture edge, and transcription
composition used in production.

| Mode | Command | Use it for |
|---|---|---|
| Standard matrix | `./scripts/transcription-benchmark.sh standard` | Compare every selectable transcription path over the fixed English, Mandarin, and bilingual fixtures. |
| Standard matrix with more repetitions | `./scripts/transcription-benchmark.sh standard --repetitions N` | Gather a larger sample; `N` must preserve the source-owned minimum. |
| Scoped reconnect | `./scripts/transcription-benchmark.sh reconnect` | Verify OpenAI reconnect, buffering, replay, final ordering, and provider identity. |

Both modes are explicit developer operations. They never run as part of `swift build`,
`./scripts/run-tests.sh`, or the normal GitHub Actions gate. The live runner needs macOS TCC access;
OpenAI arms make real provider requests, and Apple Speech may need to prepare its selected locale
model. The deterministic scorer and its edge cases still run automatically as unit tests in the
normal gate.

Run the standard matrix after changing transcription model configuration, capture delivery,
endpoint/commit/final handling, benchmark scoring, or the default transcription choice. Run reconnect
after changing WebSocket failure handling, generations, the recovery buffer, replay, or final
reconciliation. Run the relevant mode before merging or releasing a transcription-sensitive change;
ordinary UI, overlay, or coaching-only changes do not need it.

## Standard Matrix

Standard mode synthesizes each fixed non-user phrase once per run and replays the same bytes for every
repetition of that phrase. The summary records the fixture hash so repetitions cannot silently use
different input. The process tap includes only Jarvis's synthetic playback process, so unrelated
desktop audio is outside the capture and the microphone is never opened.

The matrix in
[`TranscriptionBenchmark.standardArms`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark.swift)
covers every selectable OpenAI transcription model with the matching language profile, plus Apple
Speech with one locale at a time. Standard mode requires every arm to finish every requested
repetition with continuous capture. Transcript quality and lifecycle measurements remain visible in
the summary rather than being hidden behind one universal accuracy threshold, which would make
provider comparisons less informative.

## Why Scoring Belongs to the Benchmark

A script that only plays audio and saves whatever transcript arrives is a demo, not a benchmark. A
benchmark needs a consistent way to compare the observed result with the known input and to separate
provider quality from harness or reconnect failures.

| Signal | Simple question it answers | Regression it exposes |
|---|---|---|
| Readiness latency | How long after `connect()` was the session actually usable? | Slow or missing provider setup |
| Endpoint or commit latency | How long after speech ended did the server detect the endpoint, or Jarvis send the client-owned commit? | Turn-detection or local-commit delay |
| Final latency | How long after speech ended did the accepted final arrive? | End-to-end finalization delay |
| Transcript quality and heard order | How close was the final text to the known phrase, and did fragments remain in spoken order? | Recognition errors or reordered delivery |
| Missing, duplicate, revised, or unavailable finals | Did Jarvis lose a final, deliver one twice, observe changing text for one provider item, or reach a final state without recoverable text? | Lifecycle reconciliation bugs that a plausible-looking transcript can hide |
| Capture continuity | Were captured chunk sequence numbers continuous and did they contain samples? | Audio lost before it reached the provider path |
| Replay eviction | Did the bounded recovery tail discard audio needed after interruption? | Reconnect data loss even when the replacement socket becomes ready |

These are measurements of the controlled experiment, not an audit of a user session. For example,
suppose the expected fixture is “alpha beta.” A provider could return “alpha beta” once and look
correct, while Jarvis also received the same finalized item twice. Text accuracy alone would say the
run was good; duplicate scoring reveals the lifecycle regression. Likewise, a wrong transcript with
continuous capture points toward recognition quality, while a capture sequence gap shows the input
path itself was incomplete and the provider comparison is not trustworthy.

The scoring contract lives in
[`TranscriptionBenchmark.evaluate`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark+Evaluation.swift)
and the machine-readable result types live in
[`TranscriptionBenchmark+Report.swift`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark+Report.swift).
The wiki explains what the signals mean; source remains authoritative for exact fields and acceptance
conditions.

## Scoped Reconnect Regression

Reconnect mode closes only Jarvis's active transcription WebSocket through the production
transport-failure path, then holds the replacement connection while two ordered synthetic phrases
fill the real recovery buffer. Releasing the hold exercises the normal replacement generation and
audio replay.

The mode passes a model only when one replacement generation returns both phrases exactly once and in
order, buffered chunks were actually replayed, capture stayed continuous, no required chunks were
evicted, and the configured provider/model did not change. Host Wi-Fi, Ethernet, VPNs, and other
processes remain online throughout. This is therefore an end-to-end regression of Jarvis's reconnect
and replay behavior, not a test of macOS network-outage detection.

## Artifacts, Privacy, and Interpretation

Each run writes owner-only `summary.json`, `jarvis-debug.log`, progress state, and any typed failure
under `.jarvis/transcription-benchmarks/<run>/`. The run store retains only the bounded number owned by
[`TranscriptionBenchmark.retainedRunCount`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark.swift).
Generated fixture audio lives temporarily inside that run directory and is removed at exit. Captured
PCM is never persisted.

The command exits nonzero when a platform-supported arm is unavailable or incomplete, capture
continuity fails, or the strict reconnect acceptance criteria fail. On macOS 14–25, Apple Speech arms
remain visible in `summary.json` as unavailable because that provider requires macOS 26, but they do
not fail the runnable matrix. Inspect the summary to distinguish provider recognition/finalization
behavior from capture or replay failure. Current live evidence and the next requested rerun belong in
[status.md](./status.md), not on this operating-contract page.
