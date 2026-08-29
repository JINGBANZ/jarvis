# Build, Run & the Activity Viewer

> How Jarvis is built, signed, tested, and run on macOS, plus the activity viewer. This is
> the operational *how*; the design *why* lives in [architecture.md](./architecture.md), the security
> posture in [sandbox.md](./sandbox.md). Anything here that's a plain value or wiring lives in code —
> this page captures the non-obvious mechanics and the decisions behind them.

## Toolchain — SwiftPM + Command Line Tools, no full Xcode

The Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) ships
ScreenCaptureKit, AVFoundation, AppKit, SwiftUI, Vision, CoreAudio, and Security — everything Jarvis
needs — so a SwiftUI + ScreenCaptureKit binary builds with plain `swift build`. No `.xcodeproj`.

- **Library/executable split (load-bearing for testability):** `JarvisCore` holds the pure,
  deterministic logic behind protocols (config, transcript, the coach loop, …) and is unit-tested
  with mocks on **any** machine — no Mac UI, key, or permissions needed.
  `JarvisOverlay` is a small library holding just the `NSPanel` overlay, split out so
  `JarvisOverlayTests` can import it to verify screen-capture invisibility headlessly.
  `JarvisScreenCapture` is the OS-bound `screencapture` process/file adapter behind Core's
  `ScreenCapturing` port, split out so `JarvisScreenCaptureTests` can drive its cancellation,
  cleanup-verification, and latch contract headlessly. `JarvisBrainProviders` is the
  Foundation-only concrete brain-provider library (the OpenAI Responses client and its HTTP
  failure classification), composed by the app at Start. `JarvisEvaluation` is the
  Foundation-only sealed-session evaluation library shared by the app and `EvalPrep`.
  `JarvisApp` is the thin executable that wires the libraries to the side-effectful macOS
  frameworks (mic, ScreenCaptureKit, the realtime websocket, the menu bar). That split is what
  lets most of the system be verified headless.
- **Tests use swift-testing, not XCTest.** `import XCTest` fails with "no such module" under
  CLT-only. Run the suite via **`./scripts/run-tests.sh`**, which adds the swift-testing framework
  search/rpath flags that plain `swift test` lacks CLT-only. (One sharp edge: a direct
  `@MainActor async @Test` miscompiles on the CLT swift-testing — async UI tests use a `nonisolated`
  `@Test` that `await`s a `@MainActor` helper; see `OverlayInvisibilityTests`.)

## Packaging & signing — why permission grants persist

`scripts/build-app.sh` assembles the executable into a hand-built `Jarvis Dev.app`. The production
identity remains the source in `Resources/Info.plist`; the development script edits only the assembled
copy, rewriting its name and bundle id, dropping its update feed, and stamping it as a development
build so the menu's footer caption reads a red `Dev` rather than the release version the plist carries.

**Permission persistence is a signing problem.** macOS TCC keys Screen-Recording, Microphone, and
System Audio Recording grants to **code signature + bundle id + bundle path**. An ad-hoc signature
changes every build, so macOS
forgets the grant and re-prompts on each rebuild. So `build-app.sh` always signs with a **stable
self-signed identity (`Jarvis Dev`**, created automatically on first build) — there is **no ad-hoc
fallback**. It produces `Jarvis Dev.app` with bundle id `com.jarvis.coach.dev`; the downloaded
`Jarvis.app` keeps `com.jarvis.coach` and its Developer ID signature. These intentionally incompatible
identities give each variant its own TCC grants, Launch Services registration, and bundle-id-backed
preferences, so both can be installed and run on one Mac without one variant impersonating the
other. With the development identity, bundle id, and checkout path fixed, its grants persist across
rebuilds and relaunches. On the first build macOS prompts once to let `codesign` use the new key —
click **"Always Allow"** — and the first launch requests the development app's own capture grants.

The identity split is not a second data sandbox. Both variants intentionally keep the established
owner-only API-key and direct-open session storage under `Application Support/Jarvis`; launching the
development app through `build-app.sh --run` continues to put its sessions in that checkout's
`.jarvis/`. If a checkout still contains a generated `Jarvis.app` from before the split, move only
that checkout-local bundle to the Trash so it cannot be launched accidentally; leave
`/Applications/Jarvis.app` in place.

- Recover a stale *denied* state (which macOS won't re-prompt for) with
  `tccutil reset Microphone com.jarvis.coach.dev` (or `ScreenCapture`), then relaunch `Jarvis Dev`
  and Allow. Use `com.jarvis.coach` only when intentionally resetting the production release.
- Screen Recording + Microphone are granted by **TCC prompts at first launch**, not an App-Sandbox
  entitlement file. `Permissions.primeAll()` requests them at launch and is idempotent. Core Audio
  requests System Audio Recording when Jarvis first builds its process tap after Start.

## Distribution — signed, notarized releases from CI

The `Jarvis Dev` identity above is a **local-dev** device: on any other Mac it's untrusted and
Gatekeeper blocks the app. Distributable builds go through `scripts/package-app.sh`, which builds and
signs the bundle once with a **Developer ID Application** certificate — hardened runtime + secure
timestamp (both notarization requirements) — with the `audio-input` entitlement that hardened runtime
requires for microphone capture. It submits a temporary zip of that app to Apple's notary service,
staples and validates the app's ticket, then uses the hash-pinned release-only `dmgbuild` tool to
place the stapled app beside an `Applications` shortcut in `Jarvis.dmg`. The mounted Finder window is
a fixed icon view: Jarvis on the left, Applications on the right, and a large arrow between them,
with the window chrome hidden. `dmgbuild` writes that layout metadata directly rather than automating
Finder, so the hosted runner does not need a GUI session. It deliberately leaves the signed app free
of FinderInfo extended attributes, which strict code-signature verification rejects. The script signs
and notarizes the outer disk image separately, then staples the container's ticket to the exact file
users download. Both layers therefore remain verifiable offline.

The script passes that final DMG to `scripts/verify-release.sh`, which verifies the disk image and its
ticket, mounts it read-only, and requires exactly the two visible install targets plus the hidden
Finder metadata and arrow background. `scripts/verify-dmg-layout.py` reads the final `.DS_Store` and
checks the icon view, window size, chrome, icon size and positions, background link and digest, and
Applications target position. Release verification also checks the Applications target, mounted app
version, arm64 architecture, linked macOS 26-or-newer SDK, notices, strict code signature, and
Gatekeeper policy result before detaching the image. The same SDK guard runs immediately after the
release build, before signing or notarization; the pre-container app is not accepted as a proxy for
the downloaded artifact.

Releases are cut by `.github/workflows/release.yml`, not by hand: on every push to `main`,
**release-please** maintains a standing Release PR from the conventional-commit history (bumping both
version keys in `Resources/Info.plist` via `x-release-please-version` annotations, plus the
CHANGELOG — config in `release-please-config.json`). Merging that PR is the manual release approval:
it creates the GitHub Release **as a draft**, with no second deployment approval. An Apple-silicon
`macos-26` job then runs the test gate, installs only the hash-pinned pure-Python wheels in
`scripts/requirements-release.txt` into an ephemeral environment, and signs/notarizes with secrets
scoped to the main-only `release` environment (the base64 `.p12` certificate and an App Store Connect
API key — names in the workflow). It attaches `Jarvis.dmg` and the `appcast.xml` update feed described
below, rejects any other asset, then publishes the Release. The
stable installation block in
`.github/release-header.md` links directly to that tag's DMG and explains the in-window drag to
Applications; GitHub still supplies its automatic source archives. A failed sign, notarization, or
final-image verification therefore never leaves a public Release without a validated app. The exact
runner label and binary guard keep downloaded
AppKit controls on the same macOS 26 design as local development builds instead of inheriting the
compatibility appearance of an older linked SDK. The publish job lives in the same workflow because
tags created with `GITHUB_TOKEN` never trigger other workflows.

`package-app.sh` also runs locally for packaging without CI. Create a virtual environment, install
`scripts/requirements-release.txt` with `--require-hashes`, and pass its interpreter through
`DMGBUILD_PYTHON`; notarization also needs the one-time
`xcrun notarytool store-credentials jarvis-notary …` setup. Distributed builds require macOS 14.2 or
later and run on Apple silicon only because `libjarvis-aec.a` is arm64-only. The README owns the user
installation steps; provider credentials remain user-supplied in Settings.

## In-app updates — Sparkle over the release feed

The menu bar's **Check for Updates** item runs [Sparkle](https://sparkle-project.org) against the
`appcast.xml` asset published beside each release, so an installed Jarvis can replace itself with the
newest signed disk image instead of the user re-downloading by hand. `SUFeedURL` points at
`/releases/latest/download/appcast.xml`, which GitHub resolves to the newest published Release;
`scripts/generate-appcast.sh` renders the feed after packaging, pinning the enclosure to the release's
own tag so a signed item keeps naming the exact bytes it covers once "latest" moves on.

Sparkle resolves under Command Line Tools alone: it is a remote binary target carrying a prebuilt
XCFramework, so no `.xcodeproj` is needed to consume it. SwiftPM leaves `Sparkle.framework` beside the
executable and both bundle scripts embed it at `Contents/Frameworks`, which is what the `JarvisApp`
target's rpath names. Sparkle's XPC services exist only to install updates from inside an App Sandbox;
Jarvis is not sandboxed (see [sandbox.md](./sandbox.md)), so they are deleted at embed time rather
than notarized as unreachable code. The framework brings the bundle's only nested code, so
`package-app.sh` seals it inside-out — the update helpers, the framework, then the app — and release
verification requires every nested signature to hold in the mounted artifact.

Two independent signatures gate an install: the EdDSA signature the feed records over the disk image,
checked against `SUPublicEDKey`, and the Developer ID signature, which Sparkle requires to match the
running app. That second check is also why TCC grants survive an update — macOS keys them to a code
signature that does not change between releases. The EdDSA private key is held as the
`SPARKLE_ED_PRIVATE_KEY` secret in the same `release` environment as the signing and notarization
credentials, and `generate-appcast.sh` reads it on standard input so it never reaches a process list.
Losing it would strand every installed copy on its current version. Before signing, the script derives
the key's public half and requires it to equal `SUPublicEDKey`: signing and verifying with one private
key proves only that the key is well-formed, so without this a rotated or mistyped secret would
publish a feed that every installed copy silently rejects until the next release.

Checks are user-initiated only. `SUEnableAutomaticChecks` is false, which stops both scheduled
background checks and Sparkle's first-launch prompt offering to enable them — either would present UI
on an autonomous path. The item is also disabled while a session is live, because an update dialog is
not one of the presentation paths the [runtime safety boundary](../AGENTS.md) permits during the live
pipeline, and installing quits and relaunches the app. Development bundles have no updater at all:
`build-app.sh` strips `SUFeedURL`, `UpdateController` fails to initialize without it, and the menu
omits the item rather than offering an action that a self-signed build could never complete.

## Running

| Command | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build + run the unit/offline-pipeline tests (no key, no permissions). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, sign `Jarvis Dev.app` (default `release`). Creates the `Jarvis Dev` signing identity on first run. |
| `./scripts/build-app.sh --run` | Same development build, then launch it. Per-session logs land in the workspace `.jarvis/` (see below). |

- **Always launch with `open "./Jarvis Dev.app"`**, never the bare binary — running it from a shell makes
  TCC attribute the grant to the *terminal*, so the app reports Microphone, System Audio Recording,
  or Screen Recording as "denied" even when granted. Pass flags with
  `open "./Jarvis Dev.app" --args …`.
- Production and development can stay open together, but the fixed global ⌥⌘J shortcut can belong
  to only one running process. The second app logs that the shortcut is unavailable; use its menu-bar
  controls directly or quit the other variant when testing the shortcut.
- Jarvis does **not** auto-start: choose transcription and Primary brain providers in Settings, meet
  their credential or local sign-in requirements, then **Start / Stop** from the menu. OpenAI keys
  are saved to an owner-only file; `OPENAI_API_KEY` is a headless fallback. The icon is a quiet
  monochrome tile while stopped and a lit Listening Lens in every other state: amber while starting or
  reconnecting, violet once ready, red when a Start is blocked by a requirement needing attention.

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

- New events stream in live (no reload, no flicker); thumbnails open in an in-page lightbox. Rows use
  event occurrence time, with stable insertion order only for ties, so a slower earlier transcript
  final is inserted before a faster later reply.
- Each Start opens a fresh session (a Stop→Start gets a new log, never resuming the previous run),
  persisted as owner-only `jarvis-activity.jsonl` + `shot-N.jpg`; the same directory contains
  `coaching-attempts.jsonl` for evaluator-only trigger/delta/outcome provenance and
  `brain-traffic.jsonl` for redacted wire evidence. Past runs can be browsed and the history cleared
  from the viewer. Old sessions are pruned to the most recent few at each Start.
- **The viewer and its file logging are always on** (they used to be `--dev`-gated; that flag is gone).
  On every Start, `ActivityLog` writes the coaching exchange to `jarvis-activity.jsonl` while `jlog`
  writes agent-facing diagnostics to the unified log (Console.app) and `jarvis-debug.log`. Both files
  live in the gitignored, workspace-local `.jarvis/<session>/` (`0600` files in a `0700` dir).
  `build-app.sh --run` passes that path via `--log-dir`, since the `open`-launched app can't find the
  repo itself; opening the bundle directly with no `--log-dir` falls back to
  `~/Library/Application Support/Jarvis/sessions/`. The full privacy posture is in
  [sandbox.md](./sandbox.md).
- Activity JSONL stays append-only for durable writes, but each new row carries numeric occurrence,
  insertion, and record times. Live and reopened views apply the shared Core chronology rule rather
  than treating file append order as speech order. Historical files without complete chronology
  metadata keep their original file order; second-resolution display strings are not precise enough
  to reconstruct it safely. The in-memory/live-page backstop remains 10,000 rows: Core reports the
  exact discarded insertion identities and the page removes those DOM rows before applying the next
  Core-computed insertion index.
- The viewer's rendering logic (`htmlShell`/`rowScript`) and history reader (`SessionStore`) live in
  `JarvisCore` so they're unit/WebKit-tested; `ActivityViewer` in `JarvisApp` is the thin window.
- Session evaluation is agentic only. After Stop, select a session and click **Evaluate**: the
  read-only Claude Code / Codex agent receives the source checkout plus the complete session
  directory, reads the full `jarvis-activity.jsonl` itself, and correlates first-class attempt
  provenance with raw brain traffic and screenshots. Its compact input opens with a neutral evidence
  index—artifact health, categorical distributions, and correlation-field coverage—followed by
  normalized provider-call telemetry. These tables describe recorded facts without declaring a
  defect; missing or partial values stay unavailable instead of becoming zero. Growing CLI request
  history is common-prefix elided with an explicit pointer back to untouched traffic. The agent uses
  read-only file and source-search tools to follow the evidence, then writes a generic Summary /
  Findings / Evidence gaps / Recommendations report to owner-only `eval-report.md`. A saved session
  shows **Open report** instead, avoiding another agent run. The local app locates its checkout from the
  workspace `.jarvis/`, a `--repo-dir` launch argument, or the directory containing a locally built
  app bundle; without live source it refuses to run a weaker audit. `./scripts/eval-session.sh
  [session-dir]` is the terminal launcher for the same `JarvisEvaluation` evaluator.

## System-audio transcription benchmark

The benchmark is an explicit hidden mode of the signed app. Standard mode runs fixed synthetic audio
through every selectable transcription path; reconnect mode interrupts only Jarvis's active
transcription WebSocket and exercises the real buffer/replay path. Neither mode opens the microphone,
changes host networking, or runs in the normal build/test gate.

See [transcription-benchmark.md](./transcription-benchmark.md) for commands, architecture, scoring,
acceptance, privacy, result interpretation, and when each mode should be run.

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
- Create an overlapping exchange where a longer interviewer question finalizes after a short user
  reply. Confirm Activity places the question first and the first automatic brain request uses the
  same order. Repeat while a prior brain call is in flight to exercise the queued-attempt boundary.
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
- Confirm the development build's menu has **no** update item. In a signed release build, confirm
  **Check for Updates** is greyed out while a session runs, is enabled once stopped, and reports the
  app is up to date when run against the current release.
- Choose **Stop Jarvis** and confirm Activity ends with `session ended by user`, with no later
  transcription or coaching events.
- In Activity, choose the stopped session and click **Evaluate**. Confirm the button shows
  **Evaluating…**, the report opens when the agent finishes, and the button then shows **Open report**.
  Confirm the report uses the four generic sections, cites concrete session or source anchors for
  findings, and keeps unavailable evidence in **Evidence gaps** instead of inventing a conclusion.
