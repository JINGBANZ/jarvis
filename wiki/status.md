# Status

> Snapshot of what is true *right now*. This is the entry point for picking the project up mid-stream:
> read [`index.md`](./index.md) first, then this page, then the relevant core page. Edited in place at
> the close of every change, per [`AGENTS.md`](./AGENTS.md) → "Keep-in-sync checklist". Every file
> pointer below either resolves to a real file or this page is wrong — fix the page. Design rationale
> lives on each core page beside the design it explains.

## Current phase

**General technical-interview coaching, audio reliability, and local CLI brain providers are
implemented.** The coach's capabilities are composed once at Start and the model loads what a
question needs: prep-notes search as a deferred tool, and the behavioral, coding, and system-design
skills through `load_skill`, with no Start-time selection
([architecture.md → Capabilities](./architecture.md#capabilities)). Their coaching policy and the
diagram boundary are defined in
[architecture.md → Models and APIs](./architecture.md#models-and-apis). A direct request
whose specific answer depends on visible context missing from the conversation calls `capture_screen`
before `speak`; a fresh screenshot/OCR satisfies that request, while a fully stated question can be
answered without a reflexive capture. The independent Transcription setting keeps **OpenAI as the
default**, keeps **GPT-4o Transcribe** as its default model, adds opt-in **GPT Transcribe** and
**GPT Live Transcribe**, adds opt-in, on-device **Apple Speech** on macOS 26 or later, and adds
opt-in **Gemini** over the Gemini Live WebSocket — server-owned turn detection (no client commit, no
ledger), its own model/expected-languages/vocabulary/mode Settings row set, and a 16 kHz wire format
(a provider requirement, not a quality choice — see
[architecture.md](./architecture.md#models-and-apis)). OpenAI
language expectations default to Automatic rather than English; English and Mandarin are
independent multi-select session-level hints rather than fixed combination profiles or per-turn
language choices. One Start snapshots the provider, OpenAI model/expected-language list, Gemini
model/expected-language/vocabulary/mode, or Apple locale for both `me` and `them`; there
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
transcription or appears in the brain route; a Gemini key is required only when Gemini supplies
transcription — Gemini is not a brain provider. The detailed model, language, turn-detection, context,
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
proven permanent failure—before moving forward within a cycle.
Runtime movement never changes preferences. Failed cycles keep listening within the session recovery limits; see [routing and recovery](./architecture.md#ordered-provider-route)
for the full policy. That route is implemented as immutable provider/model values, a pure
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
brain traffic, screenshots, and source code. Development evaluates against the live checkout
containing the app bundle; releases derive the recorded version from the session directory name.
`SessionStore.baseDirectory` keeps development history in that same worktree regardless of launch
method, separate from release history; see the [session-folder rule](./build-and-run.md#the-live-activity-viewer).
`SessionDirectoryID` in `Sources/JarvisCore/Diagnostics/` owns build identity and timestamp ordering;
`EvaluationSource` and `ReleaseSourceStore` in `Sources/JarvisEvaluation/` select matching source,
falling back to the running release only when the session records no version or its tag is gone, with
an explicit mismatch disclosure. Release source is downloaded per evaluation and discarded with it.
Start has no separate version-file write, and unknown version identity does not prevent evaluation.
[build-and-run.md](./build-and-run.md) defines provenance, failures,
and the Activity button states. A neutral evidence index reports artifact health,
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

Run the provider-failure live smoke, which is the only way to see the refused-handshake and
never-ready paths: with an obviously invalid OpenAI key, Start ends the session within about three
seconds naming the rejection and its close code; with a valid key and Wi-Fi off, Start ends it within
about fifteen seconds naming the network cause, with no system-audio degradation row before it; with
a valid key and network, coaching still works and `jarvis-debug.log` carries `socket #1` lines with
stage names. Both socket providers run one shared lifecycle driver, so the same walk is needed for
Gemini, plus a session left past its ten-minute cap to see the `goAway` rotation replace the
socket with no user-visible notice, and the benchmark's reconnect arm
(`./scripts/transcription-benchmark.sh`), which should report ready at generation 1, then
`reconnectPrepared`, then ready at generation 2.

Run the capability smoke in the signed app: with a prep source configured, a matching question
should show one "loaded the search_prep_notes tool" row and a tip built on the notes, and switching
Prep notes search off in Settings should leave a Start carrying neither the tool nor its catalog
line. The model's own choice to load is covered on all three brains by the opt-in
`CoachToolLoadingLiveTests` (`JARVIS_LIVE_CAPABILITY_PROVIDER`); what is left is the app path around
it, and a System Design session on a CLI brain rendering a diagram.

Run the [evaluation source smoke](./build-and-run.md#live-smoke-checklist) in a development bundle
and an installed release: source/version selection, per-run fetch and discard, actionable failures,
and cancellation on Quit. Offline tests cover the source store and evaluator; native presentation
and a real release download still need this smoke.

Run the signed-app Explain more smoke: with an interview session active, press both configured
shortcuts from another app and verify distinct hint/explanation requests; rebind them independently
and try a collision. Check automatic explanation after clear confusion, a simpler follow-up after
another Explain more press, and silence during healthy progress. Confirm longer text stays in the
capture-excluded box, caption summaries stay short, and Stop prevents late delivery. The offline
Gate covers context delivery, caption/box separation, preferences, and manual retry/coalescing;
real audio, capture, screen sharing, and shortcut use during a live interview still need this smoke.

Run a live mixed practice smoke with the OpenAI brain: request two hints on the same
untouched coding prompt, then test demonstrated understanding, a local block, a visible bug,
completion without tests, and valid progress. Move directly into a system-design question and back
to coding without changing Settings. Confirm the overlay remains at most three short lines, the
second hint advances rather than repeats, and healthy progress stays silent. This smoke verifies on-demand
screen capture, live transcript, and overlay behavior together before release.

Then run the live permission-gate smoke, since the gate runs before anything the Gate can test. After resetting each service in turn (`tccutil reset Microphone com.jarvis.coach.dev`, then
`ScreenCapture`, then `AudioCapture`) and clearing the one marker Jarvis persists (`defaults delete com.jarvis.coach.dev permissions.screenRecordingAsked`): the gate appears with no menu bar behind it; one walk collects all
three dialogs in order; **Quit** exits; refusing system audio records a refusal rather than a grant
and the probe tone stays inaudible; refusing screen recording ends on **Quit & Reopen**, and the next
launch asks once more (silent after a refusal) before offering **Open System Settings** rather than
looping; enabling Screen Recording after that
trip to Settings turns the button into **Quit & Reopen** rather than reopening Settings again;
allowing everything reaches the menu bar after one relaunch.

Then run the live smoke checklist for the lean coaching core work: Start, Stop, and an immediate
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

The Gemini live smoke with a real Gemini key passed (session `2026-09-05_11-55-54_9295`): both
sockets reached ready on the first attempt in ~310 ms, five utterances transcribed, and 134 interim
frames were correctly discarded; `grep -rc "key=" .jarvis/*/jarvis-debug.log` returned 0 files across
both a failing and a passing run, confirming the Gemini endpoint is logged without ever logging its
`key=` query. Still outstanding from that checklist: confirm selecting Gemini and pressing Start with
no Gemini key saved refuses the Start and names the missing credential, and confirm switching back to
OpenAI and starting again leaves the primary path unregressed.

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
final route exhaustion. With only one usable target, keep its brain unavailable for three attempts:
confirm retries stop, listening continues, and one fixed failure notice appears in Activity and red
on the enabled overlay. Wait through a silence check and confirm no new request is sent. Then send
a new hint or finalized speech and confirm a fresh retry budget without Start. Stop during a retry
must prevent further requests. Confirm no provider-specific tool state crosses attempts and verify a
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

**Coaching skills and tools load on demand.** A session's capabilities are one value composed at
Start (`CoachCapabilities`), and each tool carries its own usage guidance. Prep-notes search is a
deferred tool and each bundled skill a catalog entry: the prompt lists them one line each, and the
model calls `load_tool` or `load_skill` to receive the schema and guidance, or the skill's body, as
a tool result inside the turn that needs it. Settings → Brain → Capabilities switches any of them
off for the next Start; screen capture, speak, and stay silent are always on. See
[architecture.md → Capabilities](./architecture.md#capabilities).

**Show code with hints**, configured under Overlay Box with independent live code text-size and
background-opacity controls (`OverlaySection`, `OverlayAppearance`), optionally supplies the next contextual coding component with each hint.
Its capability is fixed at Start; the configurable fallback hotkey requests code for the current
guidance only in enabled sessions. Settings changes take effect on the next Start.
[`CodeSnippet`](../Sources/JarvisCore/Overlay/CodeSnippet.swift) validates bounded attachments;
[`OverlayBoxPanel`](../Sources/JarvisOverlay/OverlayBoxPanel.swift) keeps them in a syntax-colored
bottom dock while hints continue above. Code wraps and uses a compact font sized to fit the available
section; vertical scrolling remains a fallback at small panel sizes. Disabling Overlay Box turns off the saved code setting,
releases its shortcut, and clears/disables the live dock until code is enabled for a new Start.
Runtime authorization suppresses code when the session capability is off;
each new hint replaces or clears its matching snippet.
See [architecture.md](./architecture.md#on-demand-coaching-shortcuts) for behavior and failure handling.
Signed synthetic dock/shortcut checks and model scenarios cover the feature; real interview audio,
capture, cross-app shortcuts, and screen-sharing exclusion still need live verification.

Proactive clarification and a separate **Explain more** shortcut share the existing coach loop.
[`JarvisPrompts.Coach`](../Sources/JarvisCore/Prompts/JarvisPrompts+Coach.swift) supplies the policy across
formats; `speak.explanation` carries fuller plain-text detail into the persistent overlay box and
Activity while captions stay short. Activity presents labeled response sections; see
[Activity response sections](./settings-window.md#activity-response-sections) for the delivery,
replay, export, and legacy-session contract. Semibold hints and labeled, regular-weight explanation paragraphs
remain visually distinct at the configured text size. Hint and explanation shortcuts are independently configurable in Settings; **Enable explanations** controls
automatic detail and its shortcut for the next Start while retaining the saved binding.
Disabling Overlay Box turns off the saved explanation setting and releases its shortcut.
The persistent box gates detail delivery live; hidden detail is omitted from Activity and history;
see [architecture.md → On-demand coaching shortcuts](./architecture.md#on-demand-coaching-shortcuts).

See [Settings → Shortcuts](./settings-window.md#shortcuts) for when explanations are warranted
and how the explanation length guidance applies.

A design discussion supports [private high-level architecture hints](./architecture.md#private-architecture-hints):
[`DiagramHint`](../Sources/JarvisCore/Overlay/DiagramHint.swift) validates a small Mermaid subset, and
[`DiagramHintView`](../Sources/JarvisOverlay/DiagramHintView.swift) pins the latest rendered design
below the scrolling hint history inside the capture-excluded overlay box. The reference appears on
first valid delivery and survives ordinary hints and history clearing until Stop; visibility, revision,
and resizing behavior follow the linked architecture contract. What keeps a diagram to the stage that
wants one is prompt text — the tip style, the field's description, and the system-design skill — not
a runtime gate.

Tested `JarvisCore` + `JarvisBrainProviders` + `JarvisEvaluation` + `JarvisOverlay` + `JarvisScreenCapture` harness is green
(`./scripts/run-tests.sh`); `JarvisApp` is the thin OS shell, verified by the smoke run.

- `Sources/JarvisCore/Audio/` — transactional PCM + utterance buffering, bounded speech pre-roll, adaptive content-free activity detection, stable frame-decision endpoints, non-destructive AEC reference alignment, and system-audio timeline preservation (`PCMBuffer`, `SpeechGatedAudioBuffer`, `UtteranceBuffer`, `PCM16Framer`, `SpeechEndpointDetector`, `AudioDownmix`, `AdaptiveAudioActivityDetector`, `PCM16SpeechActivityTracker`, `EchoReferenceAlignment`, `SystemAudioTimeline`).
- `Sources/JarvisCore/Transcription/` — provider-neutral session/provider contracts and immutable Start configuration, selectable OpenAI model/expected-language values, the OpenAI Realtime wire contract, the Gemini Live wire contract with server-owned finalization, reconnect-safe Jarvis-managed turn coordinator and recovery state, per-item ledger, analyzer-finalization state, per-provider audio format, the socket lifecycle both WebSocket providers share (when to open, what counts as ready, which failures terminate now, how much retry budget is left), and the single spoken-time ordering policy used by the rolling transcript and Activity (`TranscriptionSession`, `SocketLifecyclePolicy`, `TranscriptionProvider`, `TranscriptionConfiguration`, `TranscriptionAudioFormat`, `OpenAITranscriptionModel`, `TranscriptionLanguage`, `TranscriptFiltering`, `RealtimeSession`, `RealtimeJarvisManagedTurnCoordinator`, `RealtimeReconnectTranscriptionRecovery`, `RealtimeTranscriptionLedger`, `GeminiLiveSession`, `GeminiTranscriptionModel`, `GeminiTranscriptionMode`, `TranscriptionFinalizationState`, `ConversationChronology`, `Transcript`, `NoiseReduction`).
- `Sources/JarvisCore/Benchmark/` + `Sources/JarvisApp/Benchmark/` — the Foundation-only fixed transcription matrix, optional absence-means-disabled instrumentation, scoring and deterministic summary contract, plus the hidden signed-app runner, process-scoped synthetic system-audio tap, and automated transcription-transport reconnect regression (`TranscriptionBenchmark`, `TranscriptionBenchmarkEvent`, `TranscriptionBenchmarkInstrumentation`, `TranscriptionBenchmarkRunner`, `SystemAudioBenchmarkCapture`; operating, isolation, and scoring contract in [transcription-benchmark.md](./transcription-benchmark.md)).
- `Sources/JarvisCore/Brain/` — the provider-neutral brain domain, and nothing that runs one: the `BrainClient`/attempt-scoped `BrainConversation` contracts, immutable `BrainTarget`/`BrainRoute`, `BrainProvider`, `BrainModelCatalog` (first per-provider entry is the default), `ReasoningEffort`, and `BrainWorkloadTimeout`. The kernel dependency guard rejects `Process`, `FileManager`, `FileHandle`, and `URLSession` here.
- `Sources/JarvisCore/Providers/` — what a failure at any provider boundary means, classified once and shared by the brain, transcription, and Settings surfaces ([architecture.md → One failure record](./architecture.md#one-failure-record-one-table-per-vendor)): the failure record with its Activity sentence table and exhaustion relabelling, the one redaction path provider text takes before a person can see it, and the Save-time credential verdict, and one classifier per vendor plus the transport table (`ProviderFailure`, `ProviderFailure+Activity`, `ProviderFailure+Exhaustion`, `ProviderMessageRedaction`, `CredentialCheck`, `TransportFailureClassifier`, `OpenAI/OpenAIFailureClassifier`, `Gemini/GeminiFailureClassifier`, `LocalAgent/LocalAgentFailureClassifier`, which owns the CLI adapters' error-domain names). Foundation-only under the kernel dependency guard: adapters hand in status codes, JSON, close reasons, and `NSError` domain and code, never `URLSession` types.
- `Sources/JarvisBrainProviders/` — every concrete brain adapter ([lean-coaching-core.md → Phase 4 contracts](./lean-coaching-core.md#phase-4-implementation-contract--openai-provider-extraction)): the OpenAI Responses transport (`OpenAIBrainClient`), and the local-agent CLI subtree — detection, `CLIBrainClient` with its reply parsing, the bounded shared process edge, runtime lifetime, and the Claude Code, Codex exec, and Codex app-server runtimes (`AgentCLIDetector`, `AgentCLIProcessRunner`, `CLIBrainRuntime`, `LocalAgentRuntimeSet`, `ClaudeCodeRuntime`, `CodexAppServerRuntime`, `CodexExecRuntime`), plus their model-facing prompt text. Depends inward on `JarvisCore`; composed by `JarvisApp` at Start, and reused by `JarvisEvaluation` to run the agentic evaluator's CLI.
- `Sources/JarvisCore/Coach/` — the event loop, split into two owners ([lean-coaching-core.md → Phase 5](./lean-coaching-core.md#phase-5-implementation-contract--coachdriver-split)): `CoachDriver` schedules (trigger coalescing, transcription-settlement admission, forward-only route state and its delivery tokens) and `CoachAttemptRunner` executes one snapshotted target (tool loop, history commit, off-path compaction), sharing only the `CoachTranscriptLedger` boundary. Plus the pure forward-only `BrainRouteSession`, `TranscriptionSettlementGate`, `CoachHistory` (client-managed session memory), `CoachCapabilities` (the session's switched-on tools
  and skills, composed once at Start), and `Tools/` (one file per coach tool, holding its name, description, schema, guidance, and result text).
- `Sources/JarvisCore/Triggers/` — turn/silence trigger detection, substance classification, and silence backoff (`Trigger`, `TurnSubstance`, `SilenceBackoff`).
- `Sources/JarvisCore/Screen/` — the model-facing screen port and the pure, Foundation-only capture logic: the `ScreenCapturing` contract, the `ScreenSnapshot` model, front-window selection over window-server candidates, and reading-order OCR layout (`ScreenCapturing`, `ScreenSnapshot`, `FrontWindowSelector`, `WindowCandidate`, `TextFragment`, `RecognizedTextLayout`). No process or file I/O; the kernel dependency guard rejects `Process`/`FileManager` here.
- `Sources/JarvisScreenCapture/` — the OS-bound screen-capture adapter behind that port ([lean-coaching-core.md → Phase 4 contract](./lean-coaching-core.md#phase-4-implementation-contract--screen-capture-adapter-move)): `ScreenCaptureRunner` owns each cancellable `screencapture` helper and the transient JPEG it writes into the owner-only session directory — it verifies that file is gone before returning, and a capture whose cleanup can't be proven latches the runner so no later capture (or display fallback) starts while a screen-derived file is unaccounted for — and `ScreenCaptureCLI` shoots the display frozen into the attempt's `SessionPlan` revision, or the main display. Depends inward on `JarvisCore`; composed by `WindowScopedScreenCapture` in `JarvisApp`; tested headlessly in `JarvisScreenCaptureTests`.
- `Sources/JarvisCore/Overlay/` — the enabled output port: overlay text model, length-proportional timing, and fan-out (`OverlayRendering`, `OverlayTiming`, `BroadcastOverlay`).
- `Sources/JarvisCore/Config/` — the control plane: config, owner-only secrets, transcription/brain/screen/overlay preferences, the immutable `SessionPlan` revision a coaching attempt runs against so no turn reads storage, and the reader for the bundled coaching skills (`Config`, `Secrets`, `Credential`, `TranscriptionPreferences`, `BrainPreferences`, `ScreenCapturePreferences`, `ScreenCaptureScope`, `OverlayAppearance`, `SessionPlan`, `Skill`, `SkillCatalog`; skill content in `Sources/JarvisCore/Resources/Skills/<name>/SKILL.md`, behavior in [architecture.md → Capabilities](./architecture.md#capabilities)). The kernel dependency guard rejects `UserDefaults`, every preference store, and `SecretStore` inside the kernel — `Config/` itself is excluded from that guard, which is why `SkillCatalog`'s file I/O lives here rather than in `Coach/`.
- `Sources/JarvisCore/Support/` — small shared runtime primitives (`Clock`, `TurnTaskBox`, `RetrySchedule`, `RetryIncident`).
- `Sources/JarvisCore/Diagnostics/` — the one [session-evidence stack](./session-audit.md) and the capture-health policy beside it: the versioned `SessionEvent` envelope and its typed producer ports, one bounded worker and per-session handle, the Activity projection with its stable persisted event kinds, occurrence/record timing, typed notices quoting the provider's redacted message inside a fixed frame, and incomplete-record signal, `jlog`'s nonblocking admission, privacy-preserving audio continuity, the capture heartbeat and its critical health policy, authoritative session-readiness composition, chronology-aware session history, and user-facing errors (`SessionEvent`, `FileSessionAudit`, `SessionAuditWorker`, `ActivityLog`, `ActivityEvent`, `ActivityEventRecording`, `BrainTrafficAuditing`, `CoachingAttemptAuditing`, `JarvisLog`, `AudioContinuityWitness`, `CaptureHeartbeat`, `CaptureReadinessMonitor`, `JarvisReadiness`, `SessionStore`, `UserFacingError`).
- `Sources/JarvisEvaluation/` — the sealed-session evaluation target ([lean-coaching-core.md → Phase 3 contract](./lean-coaching-core.md#phase-3-implementation-contract--evaluation-extraction)): loss-aware JSONL parsing, the neutral session evidence index and normalized provider telemetry, delta-aware transcript rendering, the read-only agentic audit over the complete session directory, and the HTML report page (`JSONLRecords`, `SessionAuditEvidence`, `SessionEvidenceIndex`, `SessionMetrics`, `EvaluationTranscript`, `AgenticEvaluation`, `AgenticEvaluator`, `EvalReportPage`). Depends inward on `JarvisCore` and on `JarvisBrainProviders` for the CLI plumbing its agentic evaluator runs; consumed by `JarvisApp` and `EvalPrep`.
- `Sources/JarvisCore/Prompts/` — with `Coach/Tools/`, the Foundation-only audit surface for predefined model-facing text: the whole coach system prompt in one file, the per-turn coach messages, history compaction, and transcription context (`JarvisPrompts`); the local-agent protocol text and the session-evaluation prompt extend the same namespace from `Sources/JarvisBrainProviders/Prompts/` and `Sources/JarvisEvaluation/`.
- `Sources/JarvisOverlay/` — the capture-invisible `NSPanel` surfaces: `OverlayCaptionPanel` (transient), `OverlayBoxPanel` (persistent), `NSPanel+CaptureExclusion`; plus the box's own chrome — `OverlayBoxHeaderView` and `OverlayBoxHeaderButton` (collapse, the name, clear), `OverlayBoxChrome` (header geometry derived from the box's height), and `OverlayBoxResizeAffordanceView` (the drawn edge affordance, which also owns the resize drag because macOS refuses an inactive app a resize cursor).
- `Sources/JarvisApp/App/` + `MenuBar/` — entry point and three owners ([lean-coaching-core.md → Phase 5](./lean-coaching-core.md#phase-5-implementation-contract--appdelegate-split)): `AppDelegate` is the session runtime (Start/Stop/teardown, readiness rendering and effects, capture-heartbeat handling, Settings composition), `SessionArtifacts` owns the owner-only session directory, the evidence handle in it, retention pruning, and the close bookkeeping, and `BrainComposition` owns provider preflight, brain-client and route construction, and live reapply. Plus `ErrorReporter` (startup alerts and an unconditional no-presentation runtime policy).
- `Sources/JarvisApp/Updates/UpdateController.swift` — the menu bar's Sparkle-backed **Check for Updates** item: user-initiated checks only, disabled while a session is live, and absent from development builds, which carry no feed ([build-and-run.md → In-app updates](./build-and-run.md#in-app-updates--sparkle-over-the-release-feed)).
- `Sources/JarvisApp/Capture/` — one-clock aggregate mic + sample-preserving system-audio capture that starts without waiting for a system-audio writer, with AEC3 echo cancellation, Silero voice-activity detection, and resampling to whichever wire rate the selected provider requires (`AggregateEchoCapture`, `WebRTCEchoCanceller`, `SileroVoiceActivityDetector`, `Resampler`); provider construction (`TranscriptionSessionFactory`); the one socket driver both WebSocket providers run, which owns the `URLSession`, generation counter, timers, and receive and close paths and asks `SocketLifecyclePolicy` for every decision (`WebSocketConnection`, `WebSocketConnectionAdapter`); OpenAI Realtime item/readiness/transactional-reconnect handling as one of its two adapters (`RealtimeTranscriber`); Gemini Live handling with server-owned finalization, no client-managed ledger, and the `goAway` drain (`GeminiLiveTranscriber`); macOS 26+ on-device final-result transcription and model preparation (`AppleSpeechTranscriber`, `AppleSpeechModelPreparation`); continuity/network diagnostics; permission reporting and requesting, including the self-tap tone probe that is the only way to ask for or prove the silently-enforced system-audio grant (`Permissions`, `SystemAudioPermissionProbe`); plus the window-scoped screenshot + OCR edge (`WindowScopedScreenCapture`, `ScreenTextRecognizer`).
- `Sources/JarvisApp/Onboarding/` — the launch permission gate that gathers Microphone, System Audio Recording, and Screen Recording one dialog at a time and keeps Jarvis closed until it holds all three, so no TCC prompt appears mid-session (`PermissionGate`, `PermissionsChecklistView`) ([architecture.md → Permissions](./architecture.md#permissions)).
- `Sources/JarvisApp/Settings/` — the unified Settings window (`SettingsWindow` hosting Brain behavior, shared Connections, Overlay, Screen, Prep material, and Activity sections), with shared page, rounded-card, responsive-row, and scroll primitives so every tab keeps one visual system without coupling section behavior. Saving an API key runs one models-list check (`CredentialVerifier`) and renders the vendor's verdict under the row from the same table a live session reads ([settings-window.md → Connections](./settings-window.md#connections)).
- `Sources/JarvisApp/Shortcuts/HotkeyController.swift` — the global Carbon hint, Explain more, and Show code shortcuts, with independent persisted bindings.
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
- **Gemini Live session resumption** (`sessionResumptionUpdate`) — `GeminiLiveTranscriber` drains and
  rotates ahead of the ~10-minute `goAway` close ([architecture.md → Resilience](./architecture.md#resilience)),
  which recovers the common case, but a single utterance long enough to still be in progress exactly
  when the bounded grace period elapses can still be split across the rotation. Google's own session
  resumption is the complete fix; adopting it is deliberately left as a follow-up rather than bundled
  into the drain.
