# Build, Run & the Activity Viewer

> How Jarvis is built, signed, tested, and run on macOS, plus the activity viewer. This is
> the operational *how*; the design *why* lives in [architecture.md](./architecture.md), the security
> posture in [sandbox.md](./sandbox.md). Anything here that's a plain value or wiring lives in code —
> this page captures the non-obvious mechanics and the decisions behind them.

## Toolchain

The Command Line Tools SDK (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) ships
ScreenCaptureKit, AVFoundation, AppKit, SwiftUI, Vision, CoreAudio, and Security — everything Jarvis
needs — so a SwiftUI + ScreenCaptureKit binary builds with plain `swift build`.

The Gate and the [live e2e tests](./live-e2e-tests.md) need only the Command Line Tools, which is
what CI runs; no Xcode project exists. Developer desktops also have full Xcode and the Xcode MCP,
whose macOS workflow builds, launches, stops, and reads logs, so an agent may drive the app that way;
the scripts use `open`. The live e2e tests assume the three TCC grants, an OpenAI key saved in the
secrets file, and signed-in Claude Code and Codex CLIs.

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
  lets most of the system be verified headless. `JarvisLiveTests` is the test target of the
  [live e2e tests](./live-e2e-tests.md): it drives the signed app, and it is the only test target
  that reaches real providers.
- **Tests use swift-testing, not XCTest.** `import XCTest` fails with "no such module" under
  CLT-only. Run the suite via **`./scripts/run-tests.sh`**, which adds the swift-testing framework
  search/rpath flags that plain `swift test` lacks CLT-only and passes `--skip JarvisLiveTests`, so
  the Gate compiles the live target but never runs it. `run-live-tests.sh` sources the same flags
  from `scripts/lib/swift-test-flags.sh`. (One sharp edge: a direct
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

The identity split is not a second data sandbox. Both variants intentionally share the established
owner-only API-key storage; session histories are separated by the
[session-folder rule](#the-live-activity-viewer). If a checkout still contains a generated `Jarvis.app` from before the split, move only
that checkout-local bundle to the Trash so it cannot be launched accidentally; leave
`/Applications/Jarvis.app` in place.

- Recover a stale *denied* state (which macOS won't re-prompt for) with
  `tccutil reset Microphone com.jarvis.coach.dev` (or `ScreenCapture`), then relaunch `Jarvis Dev`
  and Allow. Use `com.jarvis.coach` only when intentionally resetting the production release.
- All three grants come from **TCC prompts at launch**, not an App-Sandbox entitlement file.
  `PermissionGate` walks Microphone, System Audio Recording, and Screen Recording one dialog at a
  time and keeps Jarvis closed until it holds all three. Reset one with
  `tccutil reset AudioCapture com.jarvis.coach.dev` (or `Microphone` / `ScreenCapture`) to see the
  gate again. No grant is remembered, so nothing else has to be cleared: each launch proves what it
  holds. For a true first-run, also
  `defaults delete com.jarvis.coach.dev permissions.screenRecordingAsked`, the one marker that
  persists — it records that Jarvis asked, not that it was granted. See [architecture.md](./architecture.md#permissions).

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
users download. Both layers therefore remain verifiable offline. The install stays an explicit drag:
Jarvis never relocates itself to `/Applications` on first launch (a downloaded app can be running
translocated and read-only, and an app should not move itself), and there is no installer package,
because a single bundle needs no elevated install semantics.

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
own tag so a signed item keeps naming the exact bytes it covers once "latest" moves on. Sparkle rather
than a hand-written downloader over the Releases API: the parts a custom updater would reimplement,
signature verification and replacing the running bundle, are exactly the ones most costly to get
subtly wrong.

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
| `./scripts/run-live-tests.sh [scenario] [--evaluate] [--keep-going]` | Build the debug app and run the live e2e scenarios against real providers ([live-e2e-tests.md](./live-e2e-tests.md)). |

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
`stay_silent`. It also shows one reason whenever a live session ends — including user Stop, app quit,
replacement by a new Start, and terminal runtime failures — plus notices for failures that degrade
coaching, a settings preflight that was not applied, and a failed live brain switch falling back to
the previous provider. A failure notice keeps a fixed frame and quotes what the provider actually
said inside it: its status or close code, its error code, and its message after redaction, so a
screenshot of Activity is enough to diagnose a cause nobody has classified yet (see
[architecture.md → One failure record](./architecture.md#one-failure-record-one-table-per-vendor)).
Lifecycle sequencing, retries, and timing remain in `jarvis-debug.log`. Successful
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
- [`SessionDirectoryID`](../Sources/JarvisCore/Diagnostics/SessionDirectoryID.swift) puts the release
  version or development identity in the session directory name, beside its timestamp and random
  suffix. Start only constructs that name in memory and creates its usual session directory; there
  is no separate version-file write or version-dependent failure gate. Timestamp-only historical
  sessions remain readable with unknown version identity. Activity, retention, and the terminal
  evaluator order by the timestamp portion, so a version prefix cannot reorder history.
- **The viewer and its file logging are always on** (they used to be `--dev`-gated; that flag is gone).
  On every Start, `ActivityLog` writes the coaching exchange to `jarvis-activity.jsonl` while `jlog`
  writes agent-facing diagnostics to the unified log (Console.app) and `jarvis-debug.log`. Both files
  use the base selected by
  [`SessionStore.baseDirectory`](../Sources/JarvisCore/Diagnostics/SessionStore.swift): development
  history belongs to the checkout containing the running bundle, while releases use per-user app
  storage. The bundle location gives each worktree its own history and evaluation source, independent
  of the working directory or whether launch comes from the build script, Finder, Dock, or `open`.
  Existing histories stay where they are; there is no automatic migration or cross-variant browsing.
  Folder selection only constructs a URL; Start creates and protects its usual session directory.
  The full privacy posture is in [sandbox.md](./sandbox.md).
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
  defect; missing or partial values stay unavailable instead of becoming zero. The prompt carries no
  checklist of past incidents: one grows without bound and biases the auditor toward known failures
  while still missing the next shape. Growing CLI request
  history is common-prefix elided with an explicit pointer back to untouched traffic. The agent uses
  read-only file and source-search tools to follow the evidence, then writes a generic Summary /
  Findings / Evidence gaps / Recommendations report to owner-only `eval-report.md`. A saved session
  shows **Open report** instead, avoiding another agent run. Development builds use the live checkout
  containing `Jarvis Dev.app`, including when opened directly. The development bundle is expected to
  remain in its checkout; resolving it does not probe for or discover a relocated checkout. Release
  builds read the selected session's version from its directory name and ask
  [`ReleaseSourceStore`](../Sources/JarvisEvaluation/ReleaseSourceStore.swift) for that public tagged
  source, downloaded fresh for that one evaluation and discarded when the run ends. Nothing is cached
  between runs: the agent CLI needs the network anyway, so a cache could never rescue an offline
  evaluation. The store falls back to the running release only when the session records no version or
  its tag no longer exists. A download failure is reported against the recorded version instead of
  being retried against another one, which would fail the same way while naming a version the user
  never selected. It never searches through historical tags, and cancellation never triggers fallback.
  If no source can be obtained, evaluation reports a source-availability failure. The button shows
  **Fetching source…**, then **Evaluating…**. Source is
  required because without the prompt files a coding agent cannot distinguish a bad hint caused by
  the model from one caused by the harness. The evaluator prompt identifies release source as the
  session's exact code only when the versions match, and warns that a development checkout may have
  drifted, including uncommitted edits. Fallback prompts identify both the recorded version (or its
  absence) and the actual source used, and require source-based findings to acknowledge the mismatch.
  The saved report also carries this provenance directly, independently of the agent's output.
  Codex accepts the release workspace without requiring `.git`. Unrecoverable source failures give
  next steps in the dialog; raw errors stay in debug logs. Cancellation reaches both the download and
  subprocess, and failures preserve any saved report. Quit remains immediate: a run abandoned
  mid-download leaves only a per-user temporary directory the OS reclaims, so there is no staging,
  publication, or retention bookkeeping. Activity admits one evaluation at a time; the terminal
  evaluator uses a local checkout. Each evaluation owns its own source tree, so concurrent runs
  cannot disturb one another.
  See [sandbox.md](./sandbox.md) for source storage and permissions. `./scripts/eval-session.sh
  [session-dir]` is the terminal launcher for the same `JarvisEvaluation` evaluator.

## System-audio transcription benchmark

The benchmark is an explicit hidden mode of the signed app. Standard mode runs fixed synthetic audio
through every selectable transcription path; reconnect mode interrupts only Jarvis's active
transcription WebSocket and exercises the real buffer/replay path. Neither mode opens the microphone,
changes host networking, or runs in the normal build/test gate.

See [transcription-benchmark.md](./transcription-benchmark.md) for commands, architecture, scoring,
acceptance, privacy, result interpretation, and when each mode should be run.

## Browser screen-text validation

Focused tests in `JarvisScreenCaptureTests` cover dual Accessibility/OCR routing, secure-subtree
exclusion, bounded Unicode-safe extraction, repeated lines, inline text blocks, editor priority, and
selection among same-sized Chrome windows and multiple web areas. Fixture trees do not validate real
Chrome behavior, Vision OCR fidelity, or macOS permission transitions.

The capture behavior and source limitations are canonical in
[`settings-window.md#capture-scope`](./settings-window.md#capture-scope). Local artifacts and
provider-retention boundaries are canonical in [`sandbox.md`](./sandbox.md).

For the signed-app smoke, use Active window capture and Chrome with **Read Chrome page text** enabled:

- On a long ordinary article or problem page, capture while scrolled near the bottom and confirm the
  Accessibility block contains useful off-screen text while the OCR block matches the viewport.
- Open a virtualized editor and confirm current visible code appears through OCR even when the
  Accessibility tree exposes only a small editor region.
- Dock DevTools, then capture the page and confirm semantic text comes from the page web area. Repeat
  with two same-sized Chrome windows and confirm the screenshot and text use the focused window.
- Show a diagram and confirm the screenshot supplies visual information absent from Accessibility.
  Put text in a password field and confirm it does not appear in model-facing traffic.
- Deny or revoke Accessibility and confirm the setting remains Off while active-window OCR continues.
  Enable it while stopped, start a session, then turn it Off and confirm the next attempt omits the
  Accessibility block without presenting privacy UI.
- Confirm capture does not focus, scroll, mutate, or otherwise change Chrome. Normal bounded session
  artifacts may include `shot-N.jpg` and `brain-traffic.jsonl`, whose existing wire-audit records can
  contain current browser text. Confirm Jarvis creates no rolling image archive or separate
  browser-text archive and never replays historical screenshots.

Accessibility is not complete HTML or a complete editor buffer. Lazy, virtualized, canvas, image, and
hidden content may be absent; OCR is limited to visible pixels and may misread tokens. Jarvis sends
both current sources when available and keeps no separate historical screen-text cache.

## Live e2e tests

Behavior that needs real grants, capture devices, providers, and CLIs is verified by
`./scripts/run-live-tests.sh`, which drives the development app through scripted interview scenarios
and asserts on the session folders they leave. [live-e2e-tests.md](./live-e2e-tests.md) holds the
prerequisites, the case index, and the manual checks that stay outside the command.
