# Jarvis — Development Rules

> Rules for any coding agent (or human) working in this repo. Keep this file lean: if a rule is
> derivable from the code, it doesn't belong here. The **design** source of truth is
> [`wiki/`](./wiki/index.md) (start at [`wiki/status.md`](./wiki/status.md)); this file is about *how
> to work*, not *what we're building*.

## What this is

A personal, proactive macOS menu-bar assistant. **SwiftPM, Swift 6, macOS 14+ — no Xcode project.**

The package is split into targets along one principle: **keep the logic Foundation-only and testable,
and keep anything OS-bound thin and on the outside.**

| Target | Kind | What lives here |
|---|---|---|
| `JarvisCore` | library | All the logic. **Foundation-only** — no AppKit / AVFoundation / ScreenCaptureKit / WebKit. Runs and is unit-tested on any machine. |
| `JarvisOverlay` | library | The AppKit overlay (`NSPanel`, capture-invisibility). Its own target *so its behavior can be unit-tested* (`JarvisOverlayTests`) without dragging UIKit into Core. |
| `CJarvisAEC` | C target | The acoustic-echo-cancellation edge: a pure-C facade over WebRTC AEC3. The C++ impl is prebuilt + statically merged (abseil included, zero runtime dylibs) into `lib/libjarvis-aec.a` by `scripts/build-aec.sh`, so `swift build` only links the archive — no C++ toolchain or vendored headers. Regenerate the `.a` only when bumping the webrtc version. |
| `JarvisApp` | executable | The thin macOS shell: menu bar, capture, permissions, the dev viewer window. Wires Core + Overlay + AEC to the OS. Verified by a live run. |

> **Put logic in `JarvisCore`.** If something can be written without an OS framework, it goes in Core
> where a test can reach it. Reach outward to `JarvisOverlay` / `JarvisApp` only when you genuinely
> need AppKit/AVFoundation/ScreenCaptureKit/WebKit.

## Commands

| Task | Command | Notes |
|---|---|---|
| Compile | `swift build` | Builds all targets. |
| Test | `./scripts/run-tests.sh` | **Always use this, not raw `swift test`** — it fixes the swift-testing search path on CLT-only machines. Runs all three test targets. |
| Build the app | `./scripts/build-app.sh [release\|debug]` | Bundles + signs `Jarvis.app` with the stable `Jarvis Dev` identity (so TCC grants persist). |
| Run it | `./scripts/build-app.sh --run` | Build, then launch. Launch via `open`, never the bare binary. |
| Dev mode | `./scripts/build-app.sh --dev` | Launch with the in-app activity viewer available from the menu bar. |

## Layout

Subfolders under `Sources/<Target>/` are **organization only** — SPM globs each target's whole tree
into one module, so moving a file between subfolders never changes access control and needs no
`Package.swift` edit. Folders are grouped **by subsystem**, following the components in
[`wiki/architecture.md`](./wiki/architecture.md).

| Folder | Holds |
|---|---|
| `Sources/JarvisCore/Audio/` | PCM + utterance buffering |
| `Sources/JarvisCore/Transcription/` | Realtime session wire contract, rolling transcript |
| `Sources/JarvisCore/Coach/` | The event loop: `CoachDriver`, the brain client, tool defs |
| `Sources/JarvisCore/Triggers/` | Turn / silence trigger detection + silence backoff |
| `Sources/JarvisCore/Screen/` | Screen-capture tool contract |
| `Sources/JarvisCore/Overlay/` | Overlay text model (the rendered tip; not the window) |
| `Sources/JarvisCore/Config/` | Config + secrets (owner-only file) |
| `Sources/JarvisCore/Diagnostics/` | Logging, the dev-mode activity log, session-history store |
| `Sources/JarvisCore/Support/` | Small primitives (`Clock`, `TurnTaskBox`) |
| `Sources/JarvisOverlay/` | The on-screen `NSPanel` overlay (single file — no subfolders) |
| `Sources/JarvisApp/App/` | Entry point, `AppDelegate` |
| `Sources/JarvisApp/MenuBar/` | Menu-bar item, Start/Stop, key entry |
| `Sources/JarvisApp/Capture/` | Mic + system-audio capture, realtime transcriber, TCC priming |
| `Sources/JarvisApp/Viewer/` | Dev-mode `WKWebView` activity-viewer window |
| `Tests/JarvisCoreTests/` | Mirrors the Core subfolders; `TestFixtures.swift` stays at the root |
| `Tests/JarvisOverlayTests/` | Overlay screen-capture-invisibility checks |
| `Tests/JarvisViewerTests/` | WebKit end-to-end tests of the viewer's shipped HTML/JS |

**Where does a new file go?** Find the subsystem it belongs to and drop it in that folder. If it's
logic, it's a Core subsystem. If it's OS glue, it's a `JarvisApp` subfolder. If it's overlay window
behavior, it's `JarvisOverlay`. If no subsystem fits and it's a generic helper, `Core/Support/`.

## Conventions

- **One primary type per file**, file named exactly after the type (`CoachDriver.swift`).
- **Extensions** for a focused purpose: `Type+Purpose.swift` (e.g. `Date+Formatting.swift`).
- **Naming** follows the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
  `UpperCamelCase` types, `lowerCamelCase` everything else, clarity over brevity. Folders are `UpperCamelCase`.
- **Keep files small and single-purpose.** A file growing past a few hundred lines usually means it's
  doing two jobs — split it. Small files are easier for both humans and agents to hold in context.
- **Swift 6 strict concurrency** is on. Respect actor isolation and `Sendable`; don't silence
  warnings with `@unchecked` or `nonisolated(unsafe)` without a written reason.

## Modularity — when to add a target

- **Build the harness, not the intelligence.** If a model or an OS framework does it, don't write it.
- **Default to subfolders, not new targets.** Reorganizing within `JarvisCore` / `JarvisApp` costs
  nothing and needs no `Package.swift` change.
- **Promote a subsystem to its own target only on a concrete trigger** — it needs isolated tests, you
  want a compiler-enforced boundary, or a second executable must share it. `JarvisOverlay` is the
  worked example: it was split out of the app so its capture-invisibility behavior could be unit-tested
  while `JarvisCore` stays Foundation-only. `JarvisViewerTests` is split from `JarvisCoreTests` for the
  same reason — to keep Core's own test target UI-free.
- **No new dependencies** without a clear reason — prefer Apple frameworks and the standard library.

## Testing

- Add tests next to the right target: Core logic → `Tests/JarvisCoreTests/` under the matching
  subsystem folder; overlay behavior → `Tests/JarvisOverlayTests/`; viewer HTML/JS → `Tests/JarvisViewerTests/`.
- The suite uses **swift-testing** (`@Test` / `@Suite`, `#expect`), not XCTest.
- `JarvisApp` is intentionally **not** unit-tested — its behavior needs live TCC permissions, a mic,
  and screen capture. Verify it with the smoke checklist in
  [`wiki/specification.md` §8](./wiki/specification.md#8-self-verification-plan).
- **Before claiming anything works, run `./scripts/run-tests.sh` and read the output.** Evidence, not
  assertion.

## Safety & secrets

- **No secrets in code, ever** — not in source, tests, or examples. The API key lives in an
  owner-only `0600` file (`OPENAI_API_KEY` env var is a headless fallback only); see
  [`wiki/sandbox.md`](./wiki/sandbox.md) for why not the Keychain.
- **Nothing screen- or audio-derived is written to disk** outside dev mode. Dev-mode logs and
  screenshots go to a gitignored, owner-only `.jarvis/<session>/`. Never relax that.
- Full security posture: [`wiki/sandbox.md`](./wiki/sandbox.md).

## Workflow

- Work happens in a **git worktree** for isolation/recoverability.
- **Branch, don't commit to `main`.** Land changes via a PR that **squash-merges** with the number in
  the subject (`… (#N)`). Commit subjects are capitalized imperative ("Add…", "Fix…", "Organize…").
- The **wiki is the design source of truth.** When the phase or the "next action" changes, update
  [`wiki/status.md`](./wiki/status.md). Editing wiki pages has its own rules in
  [`wiki/CLAUDE.md`](./wiki/CLAUDE.md) — follow them for wiki changes (this file is for *code*).
- Match the surrounding code's style and density. Don't add ceremony (heavy ADRs, broad refactors)
  the project hasn't asked for — see [`wiki/CLAUDE.md`](./wiki/CLAUDE.md) on decision ceremony.
