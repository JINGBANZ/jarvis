# Build, Run & the Activity Viewer

> How Jarvis is built, signed, tested, and run on macOS, plus the activity viewer. This is
> the operational *how*; the design *why* lives in [architecture.md](./architecture.md), the security
> posture in [sandbox.md](./sandbox.md). Anything here that's a plain value or wiring lives in code —
> this page captures the non-obvious mechanics and the decisions behind them.

## Toolchain — SwiftPM + Command Line Tools, no full Xcode

The Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) ships
ScreenCaptureKit, AVFoundation, AppKit, SwiftUI, Vision, CoreAudio, and Security — everything Jarvis
needs — so a SwiftUI + ScreenCaptureKit binary builds with plain `swift build`. No `.xcodeproj`.

- **Three-target split (load-bearing for testability):** `JarvisCore` holds the pure, deterministic
  logic behind protocols (config, transcript, the coach loop, the OpenAI client, …) and is
  unit-tested with mocks on **any** machine — no Mac UI, key, or permissions needed. `JarvisOverlay`
  is a small library holding just the `NSPanel` overlay, split out so `JarvisOverlayTests` can import
  it to verify screen-capture invisibility headlessly. `JarvisApp` is the thin executable that wires
  the other two to the side-effectful macOS frameworks (mic, ScreenCaptureKit, the realtime websocket,
  the menu bar). That split is what lets most of the system be verified headless.
- **Tests use swift-testing, not XCTest.** `import XCTest` fails with "no such module" under
  CLT-only. Run the suite via **`./scripts/run-tests.sh`**, which adds the swift-testing framework
  search/rpath flags that plain `swift test` lacks CLT-only. (One sharp edge: a direct
  `@MainActor async @Test` miscompiles on the CLT swift-testing — async UI tests use a `nonisolated`
  `@Test` that `await`s a `@MainActor` helper; see `OverlayInvisibilityTests`.)

## Packaging & signing — why permission grants persist

`scripts/build-app.sh` assembles the executable into a hand-built `.app` bundle (the bundle layout
and the stable bundle id live in the script and `Resources/Info.plist`).

**Permission persistence is a signing problem.** macOS TCC keys Screen-Recording, Microphone, and
System Audio Recording grants to **code signature + bundle id + bundle path**. An ad-hoc signature
changes every build, so macOS
forgets the grant and re-prompts on each rebuild. So `build-app.sh` always signs with a **stable
self-signed identity (`Jarvis Dev`**, created automatically on first build) — there is **no ad-hoc
fallback**. With the identity, bundle id, and path all fixed, grants persist across rebuilds and
relaunches. On the first build macOS prompts once to let `codesign` use the new key — click
**"Always Allow"**.

- Recover a stale *denied* state (which macOS won't re-prompt for) with
  `tccutil reset Microphone com.jarvis.coach` (or `ScreenCapture`), then relaunch and Allow.
- Screen Recording + Microphone are granted by **TCC prompts at first launch**, not an App-Sandbox
  entitlement file. `Permissions.primeAll()` requests them at launch and is idempotent. Core Audio
  requests System Audio Recording when Jarvis first builds its process tap after Start.

## Distribution — signed, notarized releases from CI

The `Jarvis Dev` identity above is a **local-dev** device: on any other Mac it's untrusted and
Gatekeeper blocks the app. Distributable builds go through `scripts/package-app.sh`, which builds and
signs the bundle once with a **Developer ID Application** certificate — hardened runtime + secure
timestamp (both notarization requirements) — submits it to Apple's notary service, staples the
ticket, and re-zips the stapled bundle into `Jarvis-<version>.zip` (a zip itself can't be stapled,
so the archive is rebuilt after stapling). Hardened runtime denies microphone capture outright
without the `audio-input` entitlement, so the script signs with `Resources/Jarvis.entitlements`.

Releases are cut by `.github/workflows/release.yml`, not by hand: on every push to `main`,
**release-please** maintains a standing Release PR from the conventional-commit history (bumping both
version keys in `Resources/Info.plist` via `x-release-please-version` annotations, plus the
CHANGELOG — config in `release-please-config.json`). Merging that PR creates the GitHub Release **as
a draft**; a `macos-15` job then runs the test gate, signs/notarizes via repo secrets (the base64
`.p12` certificate and an App Store Connect API key — names in the workflow), attaches the zip, and
only then publishes the Release. A failed sign/notarize run therefore never leaves a public Release
without its app. The publish job lives in the same workflow because tags created with
`GITHUB_TOKEN` never trigger other workflows.

`package-app.sh` also runs locally (one-time `xcrun notarytool store-credentials jarvis-notary …`,
then just run the script) for packaging without CI. Distributed builds run on Apple Silicon only —
`libjarvis-aec.a` is arm64-only — and users supply their own OpenAI key at first run.

## Running

| Command | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build + run the unit/offline-pipeline tests (no key, no permissions). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, sign `Jarvis.app` (default `release`). Creates `Jarvis Dev` on first run. |
| `./scripts/build-app.sh --run` | Same build, then launch. Per-session logs land in the workspace `.jarvis/` (see below). |

- **Always launch with `open ./Jarvis.app`**, never the bare binary — running it from a shell makes
  TCC attribute the grant to the *terminal*, so the app reports Microphone, System Audio Recording,
  or Screen Recording as "denied" even when granted. Pass flags with
  `open ./Jarvis.app --args …`.
- Jarvis does **not** auto-start: set the OpenAI key once (Settings → Brain, saved to an owner-only
  file; `OPENAI_API_KEY` is a headless fallback), then **Start / Stop** from the menu. The icon shows
  two states only: ⚪️ stopped, 🟢 running.

## The live activity viewer

Settings → **Activity** opens an **in-app `WKWebView`** into which `ActivityLog` pushes the typed,
human-facing coaching exchange: finalized interviewer/user speech, manual hint requests, and every
brain action — a successful or failed `capture_screen`, a displayed `speak` tip, or a deliberate
`stay_silent`. It also shows one fixed, non-sensitive reason whenever a live session ends — including
user Stop, app quit, replacement by a new Start, and terminal runtime failures — plus fixed notices
for failures that degrade coaching, a settings preflight that was not applied, and a failed live brain
switch falling back to the previous provider. Provider names are allowed, while lifecycle sequencing,
raw errors, authentication details, retries, and timing remain in `jarvis-debug.log`. Successful
screen-view events carry their thumbnails as in-memory `data:` URIs. Chosen over a local HTTP server +
SSE: for an app that already holds the entries in memory, pushing into an embedded WebView is less
code, has zero network surface, and is the most testable (the production runtime *is* the test
runtime). It also sidesteps the `file://` `fetch()` restriction that forced the original viewer's
`<meta refresh>` reload.

- New events stream in live (no reload, no flicker); thumbnails open in an in-page lightbox.
- Each Start opens a fresh session (a Stop→Start gets a new log, never resuming the previous run),
  persisted as owner-only `jarvis-activity.jsonl` + `shot-N.jpg`, so past runs can be browsed and the
  history cleared from the viewer. Old sessions are pruned to the most recent few at each Start.
- **The viewer and its file logging are always on** (they used to be `--dev`-gated; that flag is gone).
  On every Start, `ActivityLog` writes the coaching exchange to `jarvis-activity.jsonl` while `jlog`
  writes agent-facing diagnostics to the unified log (Console.app) and `jarvis-debug.log`. Both files
  live in the gitignored, workspace-local `.jarvis/<session>/` (`0600` files in a `0700` dir).
  `build-app.sh --run` passes that path via `--log-dir`, since the `open`-launched app can't find the
  repo itself; opening the bundle directly with no `--log-dir` falls back to
  `~/Library/Application Support/Jarvis/sessions/`. The full privacy posture is in
  [sandbox.md](./sandbox.md).
- The viewer's rendering logic (`htmlShell`/`rowScript`) and history reader (`SessionStore`) live in
  `JarvisCore` so they're unit/WebKit-tested; `ActivityViewer` in `JarvisApp` is the thin window.
- Session evaluation is agentic only. After Stop, select a session and click **Evaluate**: the
  read-only Claude Code / Codex agent receives the source checkout plus the complete session
  directory, reads the full `jarvis-activity.jsonl` itself alongside raw brain traffic and
  screenshots, writes owner-only `eval-report.md`, and opens the rendered page. A saved session shows
  **Open report** instead, avoiding another agent run. The local app locates its checkout from the
  workspace `.jarvis/`, a `--repo-dir` launch argument, or the directory containing a locally built
  `Jarvis.app`; without live source it refuses to run a weaker audit. `./scripts/eval-session.sh
  [session-dir]` is the terminal launcher for the same Core evaluator.

## System-audio transcription benchmark

`./scripts/transcription-benchmark.sh standard` launches a hidden mode of the signed app and runs the
fixed matrix in
[`TranscriptionBenchmark`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark.swift). The matrix
covers every selectable OpenAI transcription model with its matching English, Mandarin, and bilingual
language profile, plus Apple Speech with one locale at a time. Each arm replays one synthesized,
non-user fixture at least three times. Synthesis happens once per run, the summary records the byte
hash, and every repetition replays those same bytes. The tap includes only Jarvis's own playback
process, so the benchmark neither opens the microphone nor captures unrelated system audio.

The Foundation-only evaluator reports recognition quality, final heard order, missing results,
duplicate finals, revised provider items, unavailable transcripts, and four distinct latency
boundaries:

- readiness: session `connect()` to the provider's acknowledged ready state;
- server endpoint: the end of fixture speech to an accepted server speech-stop event;
- client commit: the end of fixture speech to successful local commit transmission;
- final: the end of fixture speech to the accepted final or diagnostic-only unavailable result.

GPT-4o's server-VAD path therefore reports endpoint latency, while the client-commit models report
commit latency. Apple owns its endpoint internally and reports readiness plus final latency. The
machine-readable contract and scoring stay in the Core source above rather than being duplicated in
the wiki.

`./scripts/transcription-benchmark.sh reconnect` is a separate automated live validation for the
OpenAI paths. For each model, the hidden runner closes only the current Jarvis transcription
WebSocket through the normal transport-failure path and holds its replacement while two ordered
synthetic phrases fill the real replay buffer. It then releases the hold and passes only when the
replacement generation produces both phrases exactly once and in order, with buffered audio
replayed, no replay eviction, and no provider/model fallback. Host Wi-Fi, Ethernet, VPNs, and every
other process remain online. The scoped trigger starts at the transport-failure boundary, so this is
an end-to-end regression of Jarvis's reconnect and replay behavior, not a test of macOS network-outage
detection. This command makes real OpenAI requests and is never part of the build or test gate.

Each run writes owner-only `summary.json`, `jarvis-debug.log`, and progress files
under `.jarvis/transcription-benchmarks/<run>/`; the hidden runner prunes that tree before capture
starts to the bounded limit in
[`TranscriptionBenchmark.retainedRunCount`](../Sources/JarvisCore/Benchmark/TranscriptionBenchmark.swift).
No captured PCM is written. The synthesized fixture files are temporary, live inside that same run
directory, and are deleted before exit; a failed cleanup is explicit in the debug log. Standard mode
can request System Audio Recording permission but does not require microphone permission. Both live
modes remain explicit commands, never autonomous validation steps.

## Live smoke checklist

Some behavior can only be verified with a real key, a mic, and granted permissions. Run
`./scripts/build-app.sh --run`, choose **Start Jarvis**, and use the new
`.jarvis/<session>/jarvis-debug.log` for readiness and diagnostics. Use Settings → Activity only for
the human-facing coaching record. The current validation priority lives in
[`status.md`](./status.md#next-action).

- Start while no other app is playing audio. Confirm the macOS recording indicator appears
  immediately and that the debug log shows nonzero mic **and** system capture counters *before*
  `Jarvis: coaching ready (mic + system audio).` — readiness now waits on actual frame arrival, not
  just ready provider sockets, so system playback must not be required to wake the microphone. Then
  speak into the microphone and play speech through system audio; confirm both appear as finalized
  `heard:` entries in Activity. If frames never arrive, confirm Jarvis stops (mic) or degrades to
  microphone-only (system) instead of reporting ready.
- Show an interview question without speaking its details, then ask, “Jarvis, how can I solve this in
  one pass?” Confirm Activity shows exactly one screen view followed by a screen-specific tip. A fully
  stated behavioral question should not cause an unnecessary capture.
- On a turn where the brain has nothing useful to add, confirm Activity shows a `stayed silent`
  entry, so a deliberate no-op cannot look like a stalled brain.
- Press **⌥⌘J** with a question visible; confirm a shortcut entry, one screen view, and a tip appear in
  Activity.
- Confirm saved screenshots exclude both overlay surfaces. Toggle each overlay in Settings, verify its
  controls and preview follow the toggle, and confirm the choice survives relaunch.
- Validate realtime recovery with `./scripts/transcription-benchmark.sh reconnect`; do not disable the
  Mac's network connection. Confirm its summary reports both scoped-interruption phrases exactly once.
- Choose **Stop Jarvis** and confirm Activity ends with `session ended by user`, with no later
  transcription or coaching events.
- In Activity, choose the stopped session and click **Evaluate**. Confirm the button shows
  **Evaluating…**, the report opens when the agent finishes, and the button then shows **Open report**.
