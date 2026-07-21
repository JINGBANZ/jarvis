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

## Distribution — signed, notarized releases

The `Jarvis Dev` identity above is a **local-dev** device: on any other Mac it's untrusted and
Gatekeeper blocks the app. Distributable builds go through `scripts/package-app.sh`, which builds and
signs the bundle once with a **Developer ID Application** certificate — hardened runtime + secure
timestamp (both notarization requirements) — submits it to Apple's notary service, staples the
ticket, and re-zips the stapled bundle into `Jarvis-<version>.zip` (a zip itself can't be stapled,
so the archive is rebuilt after stapling). Hardened runtime denies microphone capture outright
without the `audio-input` entitlement, so the script signs with `Resources/Jarvis.entitlements`.

**Versioning is automated; the macOS build is local.** `.github/workflows/release.yml` runs only the
free-Linux half: on every push to `main`, **release-please** maintains a standing Release PR from the
conventional-commit history (bumping both version keys in `Resources/Info.plist` via
`x-release-please-version` annotations, plus the CHANGELOG — config in `release-please-config.json`).
Merging that PR creates the git tag (`force-tag-creation`) and a **draft** GitHub Release. The
signed, notarized build is **not** made in CI — the repo is private, so macOS runner minutes bill at
a 10x multiplier, and the Developer ID certificate lives on the maintainer's Mac. Cutting a release
is therefore: merge the Release PR, then on the Mac —

```
git pull                                    # picks up the version bump release-please committed
xcrun notarytool store-credentials jarvis-notary …   # one-time, first release only
./scripts/package-app.sh                     # → Jarvis-<version>.zip (reads the version from Info.plist)
gh release upload v<version> Jarvis-<version>.zip
gh release edit v<version> --draft=false --latest
```

The draft stays private and asset-less until that publish step, so an interrupted build never
exposes a broken release. Distributed builds run on Apple Silicon only — `libjarvis-aec.a` is
arm64-only — and users supply their own OpenAI key at first run.

> Re-enabling CI signing later (public repo, or paid macOS minutes) is a git revert of the commit
> that removed the `publish` job — the job used GitHub's standard temporary-keychain recipe and the
> `MACOS_CERTIFICATE_*` / `NOTARY_*` repo secrets, which are still set.

## Running

| Command | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build + run the unit/offline-pipeline tests (no key, no permissions). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, sign `Jarvis.app` (default `release`). Creates `Jarvis Dev` on first run. |
| `./scripts/build-app.sh --run` | Same build, then launch. Per-session logs land in the workspace `.jarvis/` (see below). |

- **Always launch with `open ./Jarvis.app`**, never the bare binary — running it from a shell makes
  TCC attribute the grant to the *terminal*, so the app reports Microphone/Screen Recording as
  "denied" even when granted. Pass flags with `open ./Jarvis.app --args …`.
- Jarvis does **not** auto-start: set the OpenAI key once (Settings → Brain, saved to an owner-only
  file; `OPENAI_API_KEY` is a headless fallback), then **Start / Stop** from the menu. The icon shows
  two states only: ⚪️ stopped, 🟢 running.

## The live activity viewer

Settings → **Activity** opens an **in-app `WKWebView`** into which `ActivityLog` pushes the typed,
human-facing coaching exchange: finalized interviewer/user speech, manual hint requests, screens
Jarvis viewed, and tips Jarvis displayed. Screen-view events carry their thumbnails as in-memory
`data:` URIs. Chosen over a local HTTP server + SSE: for an app that already holds the entries in
memory, pushing into an embedded WebView is less code, has zero network surface, and is the most
testable (the production runtime *is* the test runtime). It also sidesteps the `file://` `fetch()`
restriction that forced the original viewer's `<meta refresh>` reload.

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

## Live smoke checklist

Some behavior can only be verified with a real key, a mic, and granted permissions. Run
`./scripts/build-app.sh --run`, choose **Start Jarvis**, and use the new
`.jarvis/<session>/jarvis-debug.log` for readiness and diagnostics. Use Settings → Activity only for
the human-facing coaching record. The current validation priority lives in
[`status.md`](./status.md#next-action).

- Wait for `Jarvis: coaching ready (mic + system audio).` in the debug log. Speak into the microphone
  and play speech through system audio; confirm both appear as finalized `heard:` entries in Activity.
- Show an interview question without speaking its details, then ask, “Jarvis, how can I solve this in
  one pass?” Confirm Activity shows exactly one screen view followed by a screen-specific tip. A fully
  stated behavioral question should not cause an unnecessary capture.
- Press **⌥⌘J** with a question visible; confirm a shortcut entry, one screen view, and a tip appear in
  Activity.
- Confirm saved screenshots exclude both overlay surfaces. Toggle each overlay in Settings, verify its
  controls and preview follow the toggle, and confirm the choice survives relaunch.
- If validating realtime recovery, disconnect the network, say a unique phrase, reconnect, and confirm
  the debug log reports buffered replay and the phrase appears exactly once after recovery.
- Choose **Stop Jarvis** and confirm no later transcription or coaching events are produced.
