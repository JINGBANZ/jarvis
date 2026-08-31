# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page. The load-bearing
> design decisions live in [`decisions.md`](./decisions.md).

## Current phase

**General technical-interview coaching, audio reliability, and local CLI brain providers are
implemented.** The coach covers behavioral, system-design, and coding questions. A direct request
whose specific answer depends on visible context missing from the conversation calls `capture_screen`
before `speak`; a fresh screenshot/OCR satisfies that request, while a fully stated question can be
answered without a reflexive capture. The independent Transcription setting keeps **OpenAI as the
default**, keeps **GPT-4o Transcribe** as its default model, adds opt-in **GPT Transcribe** and
**GPT Live Transcribe**, and adds opt-in, on-device **Apple Speech** on macOS 26 or later. OpenAI
language expectations default to Automatic rather than English; English and Mandarin are
independent multi-select session-level hints rather than fixed combination profiles or per-turn
language choices. One Start snapshots the provider, OpenAI model/expected-language list, or Apple
locale for both `me` and `them`; there
is no automatic provider or model fallback. An initial same-input macOS 26 system-audio comparison
keeps GPT-4o Transcribe as the default: among the tested GPT-4o, GPT Live, and Apple Speech arms, it
alone preserved the English, Mandarin, and within-sentence language-switching inputs. This is
directional evidence rather than a full benchmark because it does not include GPT Transcribe. The
[transcription benchmark](./transcription-benchmark.md) now covers all OpenAI models and
single-locale Apple Speech with fixed synthetic English, Mandarin, and bilingual system audio, at
least three byte-identical repetitions
per arm, audio-free structured lifecycle evidence, and a deterministic summary. Its separate
reconnect mode interrupts only Jarvis's transcription WebSocket, fills the real replay buffer while
the replacement is held, then exercises the ordinary replacement path without changing host network
state. The normal app supplies no benchmark instrumentation: its session contract and `AppDelegate`
wiring expose no benchmark capability, event construction is skipped, and its direct reconnect path
is unchanged. On macOS 14.2–25, Apple Speech arms remain reported as platform-unavailable without
failing the runnable matrix. Neither mode changes defaults or runs in the gate. The first complete standard run finished
35 of 36 repetitions; one GPT Live Transcribe bilingual repetition timed out waiting for its finalized
stream while capture and delivery continuity remained intact. The automated reconnect run passes all
three OpenAI models: both scoped-interruption phrases return exactly once and in order, every model
replays buffered chunks without eviction or capture gaps, the replacement stays healthy through the
settled snapshot, and provider identity remains unchanged.
Apple Speech prepares
the selected supported locale before replacing a running pipeline, submits every captured sample to
`SpeechAnalyzer`, records only final results, and uses content-free local activity to request
analyzer finalization; coaching stays gated until the analyzer completes and matching module-result
progress is consumed, including setup and resumed-speech races. An OpenAI key is required only when OpenAI supplies
transcription or appears in the brain route. The detailed model, language, turn-detection, context,
and completion contracts live in [architecture.md](./architecture.md#models-and-apis).
The shared transcription path reconciles provider item lifecycles, preserves reconnectable audio
boundaries, salvages partial text while keeping unavailable items diagnostic-only, preserves every
real system-audio sample while padding only missing tap silence for activity detection, and keeps
AEC on a separate exact-length reference. Content-free continuity checkpoints cover capture through
provider speech without archiving PCM, and timestamp-interval correlation handles locally split or
replayed utterances without adding diagnostic text to the brain transcript. Both speaker streams
share one session time origin and one Foundation-only conversation chronology: spoken event time orders
model deltas and Activity rows, with stable insertion order only for ties. Every automatic coaching
attempt waits for both providers to report settled transcription work, so a faster later reply cannot
cross an earlier utterance into immutable model history. The manual hint remains the explicit
immediate exception. The client transcript-batching window still groups rapid final fragments; it is
not the ordering guarantee. A finalized turn carries its transcript boundary, so its delayed
transcript-batch callback is consumed if another admitted attempt already committed that line.
Reconnect-buffered OpenAI audio is pending work even before replacement server VAD creates an item.
Activity trims its live DOM, bounded in-memory chronology, and reopened-session view by the same
newest insertion identities, then orders the retained set by event time. The app combines provider
connection state with content-free capture health from the
Foundation-only
[`CaptureReadinessMonitor`](../Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift): each
stream's first positive sample-count callback establishes frame health, so valid digital silence
counts, while a missing first frame or a sustained stall after frame flow begins becomes a terminal
microphone failure or a microphone-only system degrade.
The Foundation-only
[`JarvisReadiness`](../Sources/JarvisCore/Diagnostics/JarvisReadiness.swift) composes that focused
capture result with permission, credential, brain/transcription preparation, and endpoint snapshots.
Its Start generation rejects stale and post-Stop callbacks, and its typed checking, blocked,
recovering, fully ready, microphone-only ready, and stopped states drive both the menu and the live
Activity badge. Badge changes are not Activity rows and are never persisted; a past session displays
**Ended**.
Locally accepted WebSocket sends remain in a bounded memory-only recovery tail because Realtime does
not acknowledge audio appends; server audio-clock progress retires only a safe prefix, and a
replacement socket replays the rest after a half-open failure. The scoped reconnect harness confirms
that speech captured while that socket is unavailable returns after recovery. The brain can also run
through a locally installed Claude Code or Codex CLI on the user's subscription; Brain offers both
as route targets, while Connections reports their externally managed account readiness and owns the
shared OpenAI API-key editor. Codex also remains available to the explicit agentic session
evaluator. The ordered provider route uses one primary
plus a user-editable ordered fallback list, one target per coaching attempt, no failed-request replay
inside the attempt, automatic pending-work attempts with the newest finalized transcript, the
code-owned temporary/unknown failure threshold in
[`BrainRouteSession.failuresPerTarget`](../Sources/JarvisCore/Coach/BrainRouteSession.swift)—or one
proven permanent failure—before moving forward, and no automatic return to an earlier target.
Runtime movement never changes preferences; exhausting the finite route stops coaching with a fixed
typed Activity event. That route is implemented as immutable provider/model values, a pure
Foundation-only session cursor, a single-flight fresh-attempt scheduler, and the ordered Settings
Provider editor with one uninterrupted Primary/fallback route, separate Coaching and Transcription
cards, and a Connections tab for shared authentication. A first-open install already holds a complete
route: Primary defaults to the OpenAI API, matching the transcription default so one credential covers
both. Every user setting's key, default, and valid range is declared in one place,
[`Defaults`](../Sources/JarvisCore/Config/Defaults.swift). Local coaching uses persistent runtimes rather than launching
one process per model turn. Claude Code keeps
one initialized safe-mode query ready for the active target and leases it across an attempt's
complete tool loop while preparing its replacement. It disables built-in tools, settings sources,
session persistence, and MCP servers while preserving the user's OAuth session. Its runtime miss or
crash fails the provider attempt; there is no one-shot CLI fallback. Stop kills ready, leased, and
preparing process trees. Codex keeps one session-scoped app-server under a private `CODEX_HOME` and
prepares the first target-specific ephemeral thread at Session Start while transcription connects.
The first attempt leases it; later attempts open fresh threads, so coach and summarizer share one
runtime without crossing target configuration. Its read-only, never-approval, empty-MCP,
feature-disable envelope matches what `codex exec` coaching enforced, plus verified thread
ephemerality and a message/reasoning event allowlist that aborts a turn on any other item.
Saving an API key while running also preserves those live objects: existing Realtime sockets take
the key on their next reconnect, and an OpenAI brain update remains transactional. Audio
route rebuilds likewise retry before declaring capture unavailable, and stale capture callbacks
cannot stop a new session after Stop → Start; repeated route notifications cannot reset one
incident's bounded budget. Activity persists stable event kinds and flushes at Stop. The sole evaluator is agentic: it
receives the complete session directory and reads the full, unfiltered `jarvis-activity.jsonl`
whenever it needs the user-visible sequence, alongside first-class coaching-attempt provenance, raw
brain traffic, screenshots, and live source code. A neutral evidence index reports artifact health,
categorical distributions, and correlation-field coverage; a separate normalized table reports
provider-call latency, token, cache, and cost telemetry. Both preserve unavailable and partial values
without declaring findings. The prompt gives the read-only agent file and source-search tools, asks it
to follow the recorded evidence instead of a historical-incident checklist, and returns generic
Summary / Findings / Evidence gaps / Recommendations sections. The dedicated
[session-audit component](./session-audit.md) gives the coach and brain clients only narrow optional
observer ports, then contains parsing, redaction, serialization, and file I/O behind one bounded
process worker. Regular Stop drains the old session's producers and closes its audit in a background
task, so a replacement Start uses a new directory immediately. Application Quit never waits for
audit persistence; it seals the live audit and requests a best-effort partial close before returning.
The health marker moves only from `in_progress` to terminal `complete` or `partial`. Actual queue
pressure or a persistence failure loses only the affected record and marks the final evidence partial;
later records continue where possible. A callback after sealing is rejected and logged as a lifecycle
defect, but never reopens or changes a closed audit. Evaluate for the selected session remains disabled
only while that session's normal Stop close is in progress. Surviving partial totals render as lower
bounds. CLI failures before actual transport dispatch
remain separate from provider-call totals, and malformed JSONL likewise makes affected values
explicitly partial rather than exact-looking. Historical sessions without provenance remain explicitly
unavailable. The compact transcript also
elides a growing one-item CLI history and duplicate response-envelope replies while preserving call
numbers and untouched-source access. Activity's one-click **Evaluate** action launches that evaluator
and opens its saved report; the standalone script calls the same `JarvisEvaluation` implementation. The runtime ghost-mode rule
covers microphone transcription, audio-route loss, in-place CLI preflight, and Activity-audit
completion: no runtime error autonomously activates Jarvis, opens a browser, or presents a modal;
fixed notices remain available in Activity. The gate statically rejects unreviewed presentation APIs.
The public source tree gives no public input a direct privileged-agent path. CI, release, and agent
automation use hosted runners; no self-hosted runner remains registered.
CodeRabbit reviews every pull request including forks, as a GitHub App that receives no repository
secret; the credential-bearing Claude review workflow stays limited to same-repository PR branches,
`@claude` is owner-invoked, issue discovery keeps its scheduled/manual triggers, and automatic issue
implementation relies on the central workflow's existing author write-access check. Reusable agent workflows track the shared
repository's `main` branch; retained third-party Actions are SHA-pinned and Dependabot-managed.
Public docs disclose the current unsandboxed boundary, contribution and private-reporting paths are
present, and the latest GitHub Release carries a Developer ID-signed, notarized Apple silicon app.
The release workflow builds with the macOS 26 SDK while retaining a macOS 14.2 deployment target,
then signs and notarizes one stable `Jarvis.dmg`, mounts that final image, and checks its two-item
drag-install surface plus its fixed icon view, large arrow, Applications target, linked SDK,
signature, ticket, and Gatekeeper result. The next release uploads that DMG as its only Jarvis-built
asset and links to it directly; GitHub's
automatic source archives remain. The app bundle carries the Apache license plus third-party notices. Local builds
use the independent `Jarvis Dev.app` / `com.jarvis.coach.dev` identity while releases retain
`Jarvis.app` / `com.jarvis.coach`, so their TCC grants and preferences can coexist on one Mac. The
existing Git/PR history is intentionally preserved after the full-history secret scan found no
credential leak; current-tree machine-specific instructions were generalized instead of rewriting
repository identity and provenance.

The [lean coaching core architecture](./lean-coaching-core.md) is built for issue #147. One
bounded `SessionEvidence` stack carries brain traffic, coaching attempts, agent-facing diagnostics,
and Activity through one worker, one per-session handle, one close lifecycle, and one uniform
best-effort loss contract — and the Activity window says so when a session's record is incomplete.
Retention pruning is off the Start path, capture heartbeat is split into critical policy and an
optional evidence copy, every concrete brain adapter and the screen-capture helper live outside
`JarvisCore`, a turn runs against an immutable `SessionPlan` revision rather than storage, and the
coaching coordinator and app delegate are decomposed into owners with stated boundaries. The
coaching kernel's dependency rules are enforced by `scripts/check-coaching-kernel.sh` in the Gate.

## Next action

Run the live smoke checklist for the lean coaching core work: Start, Stop, and an immediate
restart; a coaching turn with a screen view; a Settings change applied to a running session and a
failed preflight; capture readiness and system-audio degradation to microphone-only; one Claude Code
and one Codex coaching turn; and browsing a finished session in the Activity window. The offline Gate
covers everything unit-testable, but `JarvisApp` is verified live by design.

Land [#216](https://github.com/JINGBANZ/jarvis/issues/216): `CoachDriver.captureScreen` still parks
its blocking capture on the cooperative pool via `Task.detached`, which does not leave that
executor. Moving it to GCD supersedes the `.serialized` workaround on
`CoachDriverPipelineTests` / `CoachDriverManualHintTests`.

Re-enable the four agent workflows. Their hosted definitions and existing source-level gates are
ready on `main`; they were disabled during rollout so the old base-branch copies could not target the
removed self-hosted runner.
Delete the historical self-hosted runs and artifacts after owner approval: the audit found no
credential leak, but those logs expose runner, account, and installed-tool paths.
Replace release-please's `GITHUB_TOKEN` with a GitHub App token: the `main` ruleset requires the
CI `test` check, and token-authored Release PRs do not trigger `pull_request` workflows, so every
Release PR reports no such check and merges only on a repository admin's pull-request bypass.
Confirm private vulnerability reporting, secret scanning and push protection, Dependabot security
updates, and fork-workflow approval for the public repository. Keep self-hosted runners unavailable
to public forks.


Run a live chronology smoke on a fresh session: let one speaker finish a longer question while the
other gives a short reply, then confirm Activity inserts the question before the reply and the first
automatic brain request contains that same order. Repeat while a model call is already in flight so
the queued automatic attempt also waits. This requires live audio permissions and was not exercised
by the offline gate. Lower-priority runtime and coaching follow-ups from the session audit remain
parked in [issue #151](https://github.com/JINGBANZ/jarvis/issues/151).

Then repeat `./scripts/transcription-benchmark.sh standard` to classify the single GPT Live
Transcribe bilingual final-stream timeout from the first 36-repetition run. The automated scoped
reconnect run is complete and passes all three OpenAI models without changing host networking. These
live runs are not part of the gate and do not use the microphone.

Finish the remaining transcription configuration smoke:
confirm Apple Speech plus a CLI-only brain route starts without an API key, while any OpenAI
transcription or brain target still requires one. Change a transcription setting during a live run
and confirm the current snapshot remains active until the next Start; force an Apple analyzer failure
and confirm Jarvis never sends audio to OpenAI as an implicit fallback. Microphone benchmarking and
Apple-specific finalization optimization are not required.

Then run the live prompt smoke on a fresh session: show an interview question without speaking its
details, ask “Jarvis, how can I solve this in one pass?”, and confirm the first action is
exactly one `capture_screen` followed by a screen-specific reply. Then ask a fully stated behavioral
question and confirm it can answer without an unnecessary capture. Finish the in-app Claude Code
provider smoke: confirm Settings shows it signed in, then confirm a coaching turn and screen request.
While that session runs, switch providers and confirm the next completed turn preserves context and
adds the provider-only success notice to Activity; then exercise a failed replacement and confirm
the pending conversation is preserved. Verify the first-open Brain state (the OpenAI API selected as Primary,
with its model and Add fallback usable) plus the Connections **Add API key** state, then configure multiple fallbacks and force a temporary
failure-budget transition, a proven-permanent one-attempt transition, an unavailable-target skip, and
final route exhaustion. Confirm no provider-specific tool state crosses attempts and verify a
successful fallback remains active without changing preferences. Configure Codex as Primary and
confirm `jarvis-debug.log` reports the target thread ready before the first coaching request and that
the turn completes on its app-server; then Stop and confirm neither the app-server nor its private
runtime home survives. Then Stop the Claude smoke and confirm no query child remains. The signed-in
Foundation-level Claude POC already verifies two turns on one native conversation; this remaining
smoke covers app wiring, TCC, audio, and overlay presentation. Exercise one
audio-route switch: Activity should say listening continues, the
next turn should include any unsent speech, and capture should recover
without rotating the session. Stop that session, click **Evaluate**, and confirm the agentic report
opens with the four generic sections, cites exact session or source anchors for material findings,
and records unsupported conclusions as evidence gaps. The standard release checklist, including quiet-start capture before system
playback, remains in
[build-and-run.md](./build-and-run.md).

## Built

Tested `JarvisCore` + `JarvisBrainProviders` + `JarvisEvaluation` + `JarvisOverlay` + `JarvisScreenCapture` harness is green
(`./scripts/run-tests.sh`); `JarvisApp` is the thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — transactional PCM + utterance buffering, bounded speech pre-roll, adaptive content-free activity detection, stable frame-decision endpoints, non-destructive AEC reference alignment, and system-audio timeline preservation (`PCMBuffer`, `SpeechGatedAudioBuffer`, `UtteranceBuffer`, `PCM16Framer`, `SpeechEndpointDetector`, `AudioDownmix`, `AdaptiveAudioActivityDetector`, `PCM16SpeechActivityTracker`, `EchoReferenceAlignment`, `SystemAudioTimeline`).
- `Sources/JarvisCore/Transcription/` — provider-neutral session/provider contracts and immutable Start configuration, selectable OpenAI model/expected-language values, the OpenAI Realtime wire contract, reconnect-safe Jarvis-managed turn coordinator and recovery state, per-item ledger, analyzer-finalization state, and the single spoken-time ordering policy used by the rolling transcript and Activity (`TranscriptionSession`, `TranscriptionProvider`, `TranscriptionConfiguration`, `OpenAITranscriptionModel`, `OpenAITranscriptionLanguage`, `RealtimeSession`, `RealtimeJarvisManagedTurnCoordinator`, `RealtimeReconnectTranscriptionRecovery`, `RealtimeTranscriptionLedger`, `TranscriptionFinalizationState`, `ConversationChronology`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Benchmark/` + `Sources/JarvisApp/Benchmark/` — the Foundation-only fixed transcription matrix, optional absence-means-disabled instrumentation, scoring and deterministic summary contract, plus the hidden signed-app runner, process-scoped synthetic system-audio tap, and automated transcription-transport reconnect regression (`TranscriptionBenchmark`, `TranscriptionBenchmarkEvent`, `TranscriptionBenchmarkInstrumentation`, `TranscriptionBenchmarkRunner`, `SystemAudioBenchmarkCapture`; operating, isolation, and scoring contract in [transcription-benchmark.md](./transcription-benchmark.md)).
- `Sources/JarvisCore/Brain/` — the provider-neutral brain domain, and nothing that runs one: the `BrainClient`/attempt-scoped `BrainConversation` contracts, provider-neutral failure classification (`BrainFailure`), immutable `BrainTarget`/`BrainRoute`, `BrainProvider`, `BrainModelCatalog` (first per-provider entry is the default), `ReasoningEffort`, and `BrainWorkloadTimeout`. The kernel dependency guard rejects `Process`, `FileManager`, `FileHandle`, and `URLSession` here.
- `Sources/JarvisBrainProviders/` — every concrete brain adapter ([lean-coaching-core.md → Phase 4 contracts](./lean-coaching-core.md#phase-4-implementation-contract--openai-provider-extraction)): the OpenAI Responses transport with its HTTP permanence classification (`OpenAIBrainClient`, `BrainFailure+OpenAI`), and the local-agent CLI subtree — detection, `CLIBrainClient` with its reply parsing, the bounded shared process edge, runtime lifetime, and the Claude Code, Codex exec, and Codex app-server runtimes (`AgentCLIDetector`, `AgentCLIProcessRunner`, `CLIBrainRuntime`, `LocalAgentRuntimeSet`, `ClaudeCodeRuntime`, `CodexAppServerRuntime`, `CodexExecRuntime`), plus their model-facing prompt text. Depends inward on `JarvisCore`; composed by `JarvisApp` at Start, and reused by `JarvisEvaluation` to run the agentic evaluator's CLI.
- `Sources/JarvisCore/Coach/` — the event loop, split into two owners ([lean-coaching-core.md → Phase 5](./lean-coaching-core.md#phase-5-implementation-contract--coachdriver-split)): `CoachDriver` schedules (trigger coalescing, transcription-settlement admission, forward-only route state and its delivery tokens) and `CoachAttemptRunner` executes one snapshotted target (tool loop, history commit, off-path compaction), sharing only the `CoachTranscriptLedger` boundary. Plus the pure forward-only `BrainRouteSession`, `TranscriptionSettlementGate`, `CoachHistory` (client-managed session memory), and `ToolDefs` (coach tool schemas).
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection, substance classification, and silence backoff (`Trigger`, `TurnSubstance`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-facing screen port and the pure, Foundation-only capture logic: the `ScreenCapturing` contract, the `ScreenSnapshot` model, front-window selection over window-server candidates, and reading-order OCR layout (`ScreenCapturing`, `ScreenSnapshot`, `FrontWindowSelector`, `WindowCandidate`, `TextFragment`, `RecognizedTextLayout`). No process or file I/O; the kernel dependency guard rejects `Process`/`FileManager` here.
- `Sources/JarvisScreenCapture/` — the OS-bound screen-capture adapter behind that port ([lean-coaching-core.md → Phase 4 contract](./lean-coaching-core.md#phase-4-implementation-contract--screen-capture-adapter-move)): `ScreenCaptureRunner` owns each cancellable `screencapture` helper and the transient JPEG it writes into the owner-only session directory — it verifies that file is gone before returning, and a capture whose cleanup can't be proven latches the runner so no later capture (or display fallback) starts while a screen-derived file is unaccounted for — and `ScreenCaptureCLI` shoots the display frozen into the attempt's `SessionPlan` revision, or the main display. Depends inward on `JarvisCore`; composed by `WindowScopedScreenCapture` in `JarvisApp`; tested headlessly in `JarvisScreenCaptureTests`.
- `Sources/JarvisCore/Overlay/` — the enabled output port: overlay text model, length-proportional timing, and fan-out (`OverlayRendering`, `OverlayTiming`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — the control plane: config, owner-only secrets, transcription/brain/screen/overlay preferences, and the immutable `SessionPlan` revision a coaching attempt runs against so no turn reads storage (`Config`, `Secrets`, `TranscriptionPreferences`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`, `OverlayAppearance`, `SessionPlan`). The kernel dependency guard rejects `UserDefaults`, every preference store, and `SecretStore` inside the kernel.
- `Sources/JarvisCore/Support/` — small shared runtime primitives (`Clock`, `TurnTaskBox`, `RetrySchedule`, `RetryIncident`).
- `Sources/JarvisCore/Diagnostics/` — the one [session-evidence stack](./session-audit.md) and the capture-health policy beside it: the versioned `SessionEvent` envelope and its typed producer ports, one bounded worker and per-session handle, the Activity projection with its stable persisted event kinds, occurrence/record timing, fixed typed notices, and incomplete-record signal, `jlog`'s nonblocking admission, privacy-preserving audio continuity, the capture heartbeat and its critical health policy, authoritative session-readiness composition, chronology-aware session history, and user-facing errors (`SessionEvent`, `FileSessionAudit`, `SessionAuditWorker`, `ActivityLog`, `ActivityEvent`, `ActivityEventRecording`, `BrainTrafficAuditing`, `CoachingAttemptAuditing`, `JarvisLog`, `AudioContinuityWitness`, `CaptureHeartbeat`, `CaptureReadinessMonitor`, `JarvisReadiness`, `SessionStore`, `UserFacingError`).
- `Sources/JarvisEvaluation/` — the sealed-session evaluation target ([lean-coaching-core.md → Phase 3 contract](./lean-coaching-core.md#phase-3-implementation-contract--evaluation-extraction)): loss-aware JSONL parsing, the neutral session evidence index and normalized provider telemetry, delta-aware transcript rendering, the read-only agentic audit over the complete session directory, and the HTML report page (`JSONLRecords`, `SessionAuditEvidence`, `SessionEvidenceIndex`, `SessionMetrics`, `EvaluationTranscript`, `AgenticEvaluation`, `AgenticEvaluator`, `EvalReportPage`). Depends inward on `JarvisCore` and on `JarvisBrainProviders` for the CLI plumbing its agentic evaluator runs; consumed by `JarvisApp` and `EvalPrep`.
- `Sources/JarvisCore/Prompts/` — the single Foundation-only audit surface for predefined model-facing text across coaching, history compaction, and transcription context (`JarvisPrompts`); the local-agent protocol text and the session-evaluation prompt extend the same namespace from `Sources/JarvisBrainProviders/Prompts/` and `Sources/JarvisEvaluation/`.
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`.
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point and three owners ([lean-coaching-core.md → Phase 5](./lean-coaching-core.md#phase-5-implementation-contract--appdelegate-split)): `AppDelegate` is the session runtime (Start/Stop/teardown, readiness rendering and effects, capture-heartbeat handling, Settings composition), `SessionArtifacts` owns the owner-only session directory, the evidence handle in it, retention pruning, and the close bookkeeping, and `BrainComposition` owns provider preflight, brain-client and route construction, and live reapply. Plus `ErrorReporter` (startup alerts and an unconditional no-presentation runtime policy).
- `Sources/JarvisApp/Updates/UpdateController.swift` — the menu bar's Sparkle-backed **Check for Updates** item: user-initiated checks only, disabled while a session is live, and absent from development builds, which carry no feed ([build-and-run.md → In-app updates](./build-and-run.md#in-app-updates--sparkle-over-the-release-feed)).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + sample-preserving system-audio capture that starts without waiting for a system-audio writer, with AEC3 echo cancellation, Silero voice-activity detection, and resampling (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `SileroVoiceActivityDetector`, `Resampler`); provider construction (`TranscriptionSessionFactory`); OpenAI Realtime item/readiness/liveness/transactional-reconnect handling (`RealtimeTranscriber`); macOS 26+ on-device final-result transcription and model preparation (`AppleSpeechTranscriber`, `AppleSpeechModelPreparation`); continuity/network diagnostics; permissions; plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting Brain behavior, shared Connections, Overlay, Screen, and Activity sections), with shared page, rounded-card, responsive-row, and scroll primitives so every tab keeps one visual system without coupling section behavior.
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon ⌥⌘J on-demand-hint hotkey.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — the in-app `WKWebView` activity viewer, with the current non-persisted readiness badge, an exact selectable/copyable session ID, and one-click **Evaluate** / **Open report** agentic audit flow.
- `Sources/EvalPrep/main.swift` — the Foundation-only terminal entry point for the same `AgenticEvaluator` Activity invokes; `scripts/eval-session.sh` runs it over the repo + session dir.
- `Sources/CJarvisAEC/lib/libjarvis-aec.a` — the prebuilt, zero-dylib WebRTC AEC3 native edge (the `CJarvisAEC` target; rebuilt by `scripts/build-aec.sh`).
- `Sources/JarvisApp/Resources/SileroVAD.mlmodelc` — the committed Silero VAD model used for local turn detection (rebuilt by `scripts/build-vad.sh`).
- `scripts/build-app.sh` — the local self-signed `Jarvis Dev.app` build with an independent bundle id and TCC identity; its production plist source remains unchanged.
- `.github/workflows/` + `scripts/package-app.sh` + `scripts/dmg-settings.py` + `scripts/verify-dmg-layout.py` + `scripts/check-release-sdk.sh` + `scripts/verify-release.sh` — hosted automation only: owner-gated development agents, the repository gate on pull requests, then a macOS-26-SDK release-please Release PR → Developer ID-signed, notarized, stapled, mounted, Finder-layout/SDK/Gatekeeper-checked `Jarvis.dmg` with a visible drag arrow, an Applications shortcut, and bundled Apache and third-party notices; that DMG and the `appcast.xml` update feed signed over it by `scripts/generate-appcast.sh` are the Release's only Jarvis-built assets ([build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci)).
- `AGENTS.md` + `.github/workflows/sync-shared-rules.yml` — project-specific agent guidance with a
  machine-managed shared-rules block that syncs weekly from `JINGBANZ/rules`; `CLAUDE.md` imports the
  same canonical file.

## Not yet built

- **Universal binary** — `Sources/CJarvisAEC/lib/libjarvis-aec.a` is arm64-only; `lipo` in an x86_64 slice if Intel is ever needed.
- **Neural double-talk canceller** (DTLN / Muesli-style on the same aligned streams) — the escalation if AEC3 over-attenuates the user under loud far audio in practice.
