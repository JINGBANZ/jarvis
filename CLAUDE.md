# CLAUDE.md

> Rules for any coding agent (or human) working in this repo. Keep this file lean: if a rule is
> derivable from the code, it doesn't belong here. The **design** source of truth is
> [`wiki/`](./wiki/index.md) (start at [`wiki/status.md`](./wiki/status.md)); this file is about *how
> to work*, not *what we're building*.

## Project overview

A personal, proactive macOS menu-bar assistant: it hears you think aloud, watches your screen on
demand, and proactively offers short coaching tips via a capture-invisible overlay.

- **Stack:** Swift 6 (strict concurrency), SwiftPM, macOS 14+. **No Xcode project** — builds with the
  Command Line Tools.
- **Architecture:** four targets, split on one principle — **keep the logic Foundation-only and
  testable, and keep anything OS-bound thin and on the outside.**
- **Entry points:** `Sources/JarvisApp/App/` (the macOS shell); the event loop lives in
  `Sources/JarvisCore/Coach/CoachDriver.swift`.

| Target | Kind | What lives here |
|---|---|---|
| `JarvisCore` | library | All the logic. **Foundation-only** — no AppKit / AVFoundation / ScreenCaptureKit / WebKit. Runs and is unit-tested on any machine. |
| `JarvisOverlay` | library | The AppKit overlay (`NSPanel`, capture-invisibility). Its own target *so its behavior can be unit-tested* (`JarvisOverlayTests`) without dragging UIKit into Core. |
| `CJarvisAEC` | C target | The acoustic-echo-cancellation edge: a pure-C facade over WebRTC AEC3. The C++ impl is prebuilt + statically merged (abseil included, zero runtime dylibs) into `Sources/CJarvisAEC/lib/libjarvis-aec.a` by `scripts/build-aec.sh`, so `swift build` only links the archive — no C++ toolchain or vendored headers. Regenerate the `.a` only when bumping the webrtc version. |
| `JarvisApp` | executable | The thin macOS shell: menu bar, capture, permissions, the activity viewer window. Wires Core + Overlay + AEC to the OS. Verified by a live run. |

> **Put logic in `JarvisCore`.** If something can be written without an OS framework, it goes in Core
> where a test can reach it. Reach outward to `JarvisOverlay` / `JarvisApp` only when you genuinely
> need AppKit/AVFoundation/ScreenCaptureKit/WebKit.

## Setup

- **Toolchain:** the Command Line Tools are enough — **no full Xcode required**. SPM deps that rely on
  SwiftUI macros (`@Entry` / `#Preview`, e.g. `KeyboardShortcuts`) won't compile CLT-only; reach for a
  lower-level API instead (the global hotkey uses raw Carbon for this reason).
- **AEC archive:** `Sources/CJarvisAEC/lib/libjarvis-aec.a` is prebuilt and committed; `swift build` just links it.
  Regenerate it with `scripts/build-aec.sh` only when bumping the WebRTC version.
- **API key:** lives in an owner-only `0600` file (the `OPENAI_API_KEY` env var is a headless fallback
  only) — see [`wiki/sandbox.md`](./wiki/sandbox.md). Never put it in code.

## Commands

| Task | Command | Notes |
|---|---|---|
| Compile | `swift build` | Builds all targets. |
| Test | `./scripts/run-tests.sh` | **Always use this, not raw `swift test`** — it fixes the swift-testing search path on CLT-only machines. Runs all three test targets. |
| Build the app | `./scripts/build-app.sh [release\|debug]` | Bundles + signs `Jarvis.app` with the stable `Jarvis Dev` identity (so TCC grants persist). |
| Run it | `./scripts/build-app.sh --run` | Build, then launch. Launch via `open`, never the bare binary. Per-session logs land in the workspace `.jarvis/`. |
| **Gate** | `swift build && ./scripts/run-tests.sh` | The single pre-push check — run it and read the output before claiming work is done. |

## Working principles

- **Build the harness, not the intelligence.** If a model or an OS framework does it, don't write it.
- **Think before coding.** State assumptions explicitly. If a request has multiple reasonable
  interpretations, surface them and ask — don't silently pick one. Push back when something looks wrong.
- **Simplicity first.** Write the minimum code that solves the problem. No speculative features, no
  abstractions for single-use code, no error handling for cases that can't occur.
- **Surgical changes.** Every changed line should trace to the request — but it's fine to refactor or
  remove pre-existing dead code where there's clear room for improvement.
- **Goal-driven execution.** Turn the request into verifiable success criteria, state a brief plan for
  complex tasks, then loop until the criteria are met.
- **Preserve the conversational attempt boundary.** A coaching attempt snapshots one brain target for
  its entire tool loop; never retry a failed provider request or switch providers inside that attempt.
  Keep failed conversation work uncommitted, then let the scheduler start a new attempt with the latest
  finalized transcript. Runtime failover may only move forward through the user's persisted ordered
  route, never rewrite that preference or return to an exhausted target during the session. Keep the
  route and scheduling policy as Foundation-only state machines in Core; the app only supplies clients,
  timers, and speech-activity events. Temporary and unknown failures exhaust a target after three
  failed attempts; only a provider-boundary error proven permanent may exhaust it immediately, and
  even then the next provider starts only in a fresh attempt.

## Workflow

- **Explore → plan → implement.** For non-trivial changes, understand the relevant code and agree on an
  approach before editing. Skip planning only for small, well-scoped fixes.
- **Evidence, not assertion.** Before claiming anything works, run the **Gate** and read the output.
- **Match existing patterns.** Before adding a file, find where similar code lives and mirror its
  structure, naming, and idioms. Don't impose a pattern the repo doesn't already use.
- **Work in a git worktree** for isolation/recoverability.
- **The wiki is the design source of truth.** When the phase or the "next action" changes, update
  [`wiki/status.md`](./wiki/status.md). Editing wiki pages has its own rules in
  [`wiki/CLAUDE.md`](./wiki/CLAUDE.md) — follow them for wiki changes (this file is for *code*).
- Don't add ceremony (heavy ADRs, broad refactors) the project hasn't asked for — see
  [`wiki/CLAUDE.md`](./wiki/CLAUDE.md) on decision ceremony.

## Layout

Subfolders under `Sources/<Target>/` are **organization only** — SPM globs each target's whole tree
into one module, so moving a file between subfolders never changes access control and needs no
`Package.swift` edit. Folders are grouped **by subsystem**, following the components in
[`wiki/architecture.md`](./wiki/architecture.md).

| Folder | Holds |
|---|---|
| `Sources/JarvisCore/Audio/` | PCM + utterance buffering |
| `Sources/JarvisCore/Transcription/` | Realtime session wire contract, rolling transcript |
| `Sources/JarvisCore/Brain/` | The LLM integration: the `BrainClient` contract + provider clients (OpenAI API, Claude Code / Codex CLI), model catalog, CLI detection |
| `Sources/JarvisCore/Coach/` | The event loop: `CoachDriver`, session memory, tool defs |
| `Sources/JarvisCore/Triggers/` | Turn / silence trigger detection + silence backoff |
| `Sources/JarvisCore/Screen/` | Screen-capture tool contract |
| `Sources/JarvisCore/Overlay/` | Overlay text model (the rendered tip; not the window) |
| `Sources/JarvisCore/Config/` | Config + secrets (owner-only file) |
| `Sources/JarvisCore/Diagnostics/` | Logging, the activity log, session-history store |
| `Sources/JarvisCore/Support/` | Small primitives (`Clock`, `TurnTaskBox`) |
| `Sources/JarvisOverlay/` | The on-screen `NSPanel` overlay surfaces (caption + box; no subfolders) |
| `Sources/JarvisApp/App/` | Entry point, `AppDelegate` |
| `Sources/JarvisApp/MenuBar/` | Menu-bar item, Start/Stop, key entry |
| `Sources/JarvisApp/Capture/` | Mic + system-audio capture, realtime transcriber, TCC priming |
| `Sources/JarvisApp/Viewer/` | The `WKWebView` activity-viewer window |
| `Tests/JarvisCoreTests/` | Mirrors the Core subfolders; `TestFixtures.swift` stays at the root |
| `Tests/JarvisOverlayTests/` | Overlay screen-capture-invisibility checks |
| `Tests/JarvisViewerTests/` | WebKit end-to-end tests of the viewer's shipped HTML/JS |

**Where does a new file go?** Find the subsystem it belongs to and drop it in that folder. If it's
logic, it's a Core subsystem. If it's OS glue, it's a `JarvisApp` subfolder. If it's overlay window
behavior, it's `JarvisOverlay`. If no subsystem fits and it's a generic helper, `Core/Support/`.

## Code style

- **One primary type per file**, file named exactly after the type (`CoachDriver.swift`).
- **Extensions** for a focused purpose: `Type+Purpose.swift` (e.g. `Date+Formatting.swift`).
- **Naming** follows the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
  `UpperCamelCase` types, `lowerCamelCase` everything else, clarity over brevity. Folders are `UpperCamelCase`.
- **Keep files small and single-purpose.** A file growing past a few hundred lines usually means it's
  doing two jobs — split it. Small files are easier for both humans and agents to hold in context.
- **Swift 6 strict concurrency** is on. Respect actor isolation and `Sendable`; don't silence warnings
  with `@unchecked` or `nonisolated(unsafe)` without a written reason.
- Document non-obvious decisions in comments — explain *why*, not *what*.

## Modularity — when to add a target

- **Default to subfolders, not new targets.** Reorganizing within `JarvisCore` / `JarvisApp` costs
  nothing and needs no `Package.swift` change.
- **Promote a subsystem to its own target only on a concrete trigger** — it needs isolated tests, you
  want a compiler-enforced boundary, or a second executable must share it. `JarvisOverlay` is the
  worked example: it was split out of the app so its capture-invisibility behavior could be unit-tested
  while `JarvisCore` stays Foundation-only. `JarvisViewerTests` is split from `JarvisCoreTests` for the
  same reason — to keep Core's own test target UI-free.
- **No new dependencies** without a clear reason — prefer Apple frameworks and the standard library.

## Testing

- **Framework:** **swift-testing** (`@Test` / `@Suite`, `#expect`), not XCTest.
- **Where tests live:** next to the right target — Core logic → `Tests/JarvisCoreTests/` under the
  matching subsystem folder; overlay behavior → `Tests/JarvisOverlayTests/`; viewer HTML/JS →
  `Tests/JarvisViewerTests/`.
- **Expectations:** add/extend tests for behavior changes. Don't add production seams or hooks just to
  enable a test — make the test adapt instead.
- `JarvisApp` is intentionally **not** unit-tested — its behavior needs live TCC permissions, a mic,
  and screen capture. Verify it with the [live smoke checklist](./wiki/build-and-run.md#live-smoke-checklist).
- **Before claiming anything works, run `./scripts/run-tests.sh` and read the output.** Evidence, not
  assertion.

## Repository etiquette

- **Branches:** branch, don't commit to `main`.
- **Pull requests:** land changes via a PR that **squash-merges** with the number in the subject
  (`… (#N)`).
- **Never commit:** secrets, generated artifacts, or large binaries.

### Commit messages

Follow [Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary` in
lowercase imperative mood (`feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`).
Mark breaking changes with `!` (`feat!:`) or a `BREAKING CHANGE:` footer. One logical change per commit.
The squash-merge subject carries the PR number (`type: summary (#N)`).

## Security & safety

- **No secrets in code, ever** — not in source, tests, or examples. The API key lives in an owner-only
  `0600` file (`OPENAI_API_KEY` env var is a headless fallback only); see
  [`wiki/sandbox.md`](./wiki/sandbox.md) for why not the Keychain.
- **Preserve ghost mode for the whole coaching lifecycle.** From a live pipeline through terminal
  teardown, no autonomous path may activate Jarvis, change its activation policy, present an alert,
  sheet, or window, open another app or URL, request attention, post a notification, or play a sound.
  Only `OverlayCaptionPanel` and `OverlayBoxPanel` may present automatically; both must remain
  nonactivating and capture-excluded. Runtime failures stop or degrade silently, append fixed typed
  copy to Activity, and put raw detail only in `jarvis-debug.log`. The persistent menu-bar item,
  explicit user actions that open Settings/Activity, and unavoidable macOS privacy UI are the named
  exceptions. Every presentation API call needs an inline `ghost-mode-allowed` reason so
  `scripts/check-ghost-mode.sh` can enforce the boundary in the normal test gate.
- **Keep human activity separate from agent diagnostics.** `ActivityLog` is the human-facing coaching
  record: finalized interviewer/user speech, manual hint requests, every brain action (`capture_screen`
  success or failure, `speak`, and `stay_silent`), fixed typed brain-change notices, and fixed typed
  notices for every runtime failure that stops or degrades coaching belong there. Lifecycle,
  transport, retry, raw error, timing, and diagnosis details go through `jlog` to
  `jarvis-debug.log`. Never mirror `jlog` into `ActivityLog`; record the corresponding typed activity
  event explicitly.
- **The only screen-/audio-derived data persisted to disk is the per-session log directory** (the
  activity log — spoken tips, deliberate-silence and fixed failure notices, transcribed "heard:"
  lines, and the screenshots the model looked at — plus the wire-level brain traffic record and its
  on-demand evaluation report). It is written every run to an
  **owner-only** (`0600` files in a `0700` dir) per-session directory in the gitignored, workspace-local
  `.jarvis/`, pruned to the most recent few sessions, never `/tmp`. The raw mic audio and the live
  transcript are **never** archived. Keep the owner-only, no-`/tmp`, workspace-local posture.
- Full security posture: [`wiki/sandbox.md`](./wiki/sandbox.md).

## Never

- **Never** commit directly to `main` — open a PR.
- **Never** put secrets in source, tests, or examples; never persist screen-/audio-derived data outside
  the owner-only workspace-local `.jarvis/`, and never to `/tmp`.
- **Never** silence Swift 6 concurrency warnings with `@unchecked` or `nonisolated(unsafe)` without a
  written reason.
- **Never** copy schemas, prompts, or config values from `Sources/` into the wiki — link to the source
  file instead, or it drifts.
- **Never** modify or delete a test to make a broken change pass — fix the code, not the test.

## Gotchas

- **CLT-only build:** SPM deps using SwiftUI macros (`@Entry` / `#Preview`) won't compile; use a
  lower-level API (the hotkey uses raw Carbon).
- **Run the app via `open`, never the bare binary** — TCC grants attach to the signed `.app`.
- **`libjarvis-aec.a` is arm64-only**; `lipo` it in an x86_64 build if Intel is ever needed.
- Use `./scripts/run-tests.sh`, not raw `swift test`, or swift-testing won't be found on CLT-only machines.

## Further context

- **Design source of truth:** @wiki/index.md — architecture, decisions, and current status. Start at
  [`wiki/status.md`](./wiki/status.md) if you're picking the project up mid-stream.
- Contribution guide: @CONTRIBUTING.md (if present)
