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

**Permission persistence is a signing problem.** macOS TCC keys a Screen-Recording/Microphone grant
to **code signature + bundle id + bundle path**. An ad-hoc signature changes every build, so macOS
forgets the grant and re-prompts on each rebuild. So `build-app.sh` always signs with a **stable
self-signed identity (`Jarvis Dev`**, created automatically on first build) — there is **no ad-hoc
fallback**. With the identity, bundle id, and path all fixed, grants persist across rebuilds and
relaunches. On the first build macOS prompts once to let `codesign` use the new key — click
**"Always Allow"**.

- Recover a stale *denied* state (which macOS won't re-prompt for) with
  `tccutil reset Microphone com.jarvis.coach` (or `ScreenCapture`), then relaunch and Allow.
- Screen Recording + Microphone are granted by **TCC prompts at first run**, not an App-Sandbox
  entitlement file. `Permissions.primeAll()` requests them at launch and is idempotent.

## Running

| Command | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build + run the unit/offline-pipeline tests (no key, no permissions). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, sign `Jarvis.app` (default `release`). Creates `Jarvis Dev` on first run. |
| `./scripts/build-app.sh --run` | Same build, then launch. Per-session logs land in the workspace `.jarvis/` (see below). |

- **Always launch with `open ./Jarvis.app`**, never the bare binary — running it from a shell makes
  TCC attribute the grant to the *terminal*, so the app reports Microphone/Screen Recording as
  "denied" even when granted. Pass flags with `open ./Jarvis.app --args …`.
- Jarvis does **not** auto-start: set the OpenAI key once via the menu bar ("Set OpenAI API Key…",
  saved to an owner-only file; `OPENAI_API_KEY` is a headless fallback), then **Start / Stop** from the
  menu. The icon shows two states only: ⚪️ stopped, 🟢 running.

## The live activity viewer

Settings → **Activity** opens an **in-app `WKWebView`** window into which Swift *pushes* each `jlog`
line (and `capture_screen` thumbnails as in-memory `data:` URIs). Chosen over a local HTTP server +
SSE: for an app that already holds the entries in memory, pushing into an embedded WebView is less
code, has zero network surface, and is the most testable (the production runtime *is* the test
runtime). It also sidesteps the `file://` `fetch()` restriction that forced the original viewer's
`<meta refresh>` reload.

- New events stream in live (no reload, no flicker); thumbnails open in an in-page lightbox.
- Each Start opens a fresh session (a Stop→Start gets a new log, never resuming the previous run),
  persisted as owner-only `jarvis-activity.jsonl` + `shot-N.jpg`, so past runs can be browsed and the
  history cleared from the viewer. Old sessions are pruned to the most recent few at each Start.
- **The viewer and its file logging are always on** (they used to be `--dev`-gated; that flag is gone).
  On every launch `jlog` writes to the unified log (Console.app) *and* the per-session files in the
  gitignored, workspace-local `.jarvis/<session>/` (`0600` files in a `0700` dir). `build-app.sh --run`
  passes that path via `--log-dir`, since the `open`-launched app can't find the repo itself; opening
  the bundle directly with no `--log-dir` falls back to `~/Library/Application Support/Jarvis/sessions/`.
  The full privacy posture is in [sandbox.md](./sandbox.md).
- The viewer's rendering logic (`htmlShell`/`rowScript`) and history reader (`SessionStore`) live in
  `JarvisCore` so they're unit/WebKit-tested; `ActivityViewer` in `JarvisApp` is the thin window.

## Live smoke checklist

Some behavior can only be verified by a human with a real key, a mic, and granted permissions — see
the checklist in the [README](../README.md#live-smoke-checklist). Run via `./scripts/build-app.sh
--run` and watch each step in the activity viewer (Settings → Activity).
