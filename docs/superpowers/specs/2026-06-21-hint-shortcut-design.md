# On-demand hint shortcut (one round trip) — design

**Date:** 2026-06-21
**Status:** Approved (pending spec review)

## Problem

A screen-aware hint costs **two** brain round trips today. The model has no eyes until it
calls the `capture_screen` tool, so the loop is: trigger → model emits `capture_screen` →
`CoachDriver` runs the screenshot and re-injects it → model reasons again and finally speaks.
That second trip is pure latency, and it only happens reactively (when audio triggers a turn).

We want a **deliberate, user-initiated** way to get a hint *right now*, in **one** round trip:
the user presses a global keyboard shortcut, the app grabs a screenshot itself, injects it plus a
synthetic "give me a hint" user message into the *first* request, and forces the model to speak.

## Goal

Press a global hotkey → screenshot + synthetic hint request go to the brain in one call →
a hint appears on the overlay. Works while a session is running, with full meeting context.

## Decisions (settled during brainstorming)

| Question | Decision |
|---|---|
| When is the shortcut active? | **Only while a session is running.** Reuses the live brain client, server-side conversation, and rolling transcript so the hint has full context. If stopped, the keypress is ignored (with an `NSSound.beep()` so it isn't silently dead). |
| Hotkey mechanism | **Raw Carbon `RegisterEventHotKey`** (no dependency). It is the one global-shortcut API Apple never modernized; needs **no Accessibility/TCC permission and no permission dialog**, and — unlike the `KeyboardShortcuts` package — builds cleanly with the Command Line Tools. See the constraint note below. |
| Customizable? | **No — fixed `⌥⌘J` for now.** A rebinding UI can come later; the value here is the one-trip hint, not the binding control. |
| Synthetic message | **Fixed generic prompt** (hard-coded, not configurable). |
| Force a reply? | **Yes — force the `speak` tool** (`ToolChoice.force("speak")`) so a keypress always yields a visible hint. |

> **Why not the `KeyboardShortcuts` package?** It was the first choice (industry standard, ships a
> recorder UI), but every modern release uses SwiftUI macros (`@Entry` in 3.x, `#Preview` in 2.x)
> whose plugins ship **only with full Xcode**. Jarvis builds **CLT-only** (`run-tests.sh` even
> patches the CLT swift-testing path; `xcode-select -p` here is `/Library/Developer/CommandLineTools`),
> so the package fails to compile in this environment regardless of version. Raw Carbon needs no
> macros and no dependency, and has the identical permission profile. The only thing given up is the
> free recorder UI — which we weren't shipping in the fixed-binding scope anyway.

## Architecture

Four changes, three of them small. The one-trip mechanic lives in `JarvisCore` (testable); the
hotkey and Settings UI live in `JarvisApp` (OS glue).

### 1. New trigger: `.manualHint` — `Sources/JarvisCore/Triggers/Trigger.swift`

Add a case to `TriggerReason`:

```swift
case manualHint   // the user pressed the hint hotkey — capture + force a hint, one trip
```

Add its `promptLine` in `TriggerContext` (the fixed synthetic message), e.g.:

> "Trigger: the user pressed the hint shortcut. They want your single most useful hint about
> what's on their screen right now — answer based on the attached screenshot and the recent
> transcript. The session has been running for Ns."

`TriggerReason` is `Equatable`/`Sendable`; adding a case is source-compatible. The existing
`switch` in `runTurn` (`if case .silence`) is non-exhaustive, so no other switch breaks.

### 2. Direct screenshot injection + forced speak — `Sources/JarvisCore/Coach/CoachDriver.swift`

In `runTurn(_:)`, after the base `convo` is built (the `.system` + optional prior-close +
`.user(...)` at lines ~185–195) and **before** the tool loop:

- **If `reason == .manualHint`:** capture the screen up front, reusing the exact off-pool +
  cancellation pattern already used in the `.captureScreen` tool branch (lines ~244–249):

  ```swift
  let screen = self.screen
  let img = await Task.detached(priority: .userInitiated) { screen.capture() }.value
  if Task.isCancelled { return .cancelled }
  if let img {
      jlog("👁 looking at your screen", image: img)
      convo.append(.userImage(img))
  } else {
      jlog("👁 screenshot failed")
      // still proceed — force a hint from transcript/conversation context alone
  }
  ```

  The synthetic "give me a hint" text is already in the `.user(...)` message via
  `ctx.promptLine`, so no separate text message is needed.

- **Tool choice:** make the `toolChoice` passed to `brain.respond` a per-turn value instead of
  the hard-coded `.auto` (line 210):

  ```swift
  let turnToolChoice: ToolChoice = (reason == .manualHint) ? .force(speakTool.name) : .auto
  ```

  Forcing `speak` means the model **cannot** call `capture_screen` this turn (the image is
  already attached) and must return a hint — guaranteeing the single-trip, always-visible result.
  After the forced `speak`, the existing `.speak` branch renders to the overlay and returns
  `.spoke` on the first iteration.

Everything else is unchanged: conversation continuity (delta vs. stateless window), the
prior-close bundling, the commit-after-send ordering, coalescing, and Stop-cancellation all keep
working because `.manualHint` flows through the same `handleTrigger` → `runTurn` path.

> **Note on the system prompt:** it says "You cannot see the screen unless you call
> capture_screen." That stays true for audio-driven turns. For a manual hint the image is provided
> directly as an `input_image`, and `speak` is forced, so the model answers from what it sees
> regardless of that line. No prompt change required.

### 3. Global hotkey — `Sources/JarvisApp/Shortcuts/HotkeyController.swift`

A thin `@MainActor` type that registers the fixed ⌥⌘J hot key via Carbon and exposes a callback,
mirroring how `MenuBarController` exposes `onStart`/`onStop`:

- `installHandler()` calls `InstallEventHandler(GetApplicationEventTarget(), …)` for
  `kEventHotKeyPressed`. The C callback can't capture context, so `self` is handed in via `userData`
  and recovered with `Unmanaged`. Carbon delivers application-target hot-key events on the main
  thread, so the callback uses `MainActor.assumeIsolated { controller.onRequestHint?() }`.
- `register()` calls `RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(cmdKey | optionKey), …)`.
- No `deinit` teardown: the controller is app-lifetime (like the menu bar / overlay), and the OS
  reclaims the registration on process exit. (A `deinit` couldn't touch the non-`Sendable` Carbon
  pointers under Swift 6 strict concurrency anyway.)

### 4. Wiring — `Sources/JarvisApp/App/AppDelegate.swift`

In `applicationDidFinishLaunching`, alongside the existing menu-callback wiring, construct the
`HotkeyController` and route its callback through the same `TurnTaskBox` the transcriber callbacks
use:

```swift
hotkeys = HotkeyController()
hotkeys?.onRequestHint = { [weak self] in
    guard let self, let fire = self.requestManualHint else { NSSound.beep(); return }  // no session
    fire()
}
```

Rather than store the whole driver, `AppDelegate` stores a `requestManualHint: (() -> Void)?` closure
that captures the `Sendable` driver + turn box — the same trick the transcriber callbacks already use
(`turns.run { await driver.handleTrigger(.manualHint) }`). It's set in `start()` and cleared in
`stop()`, so it is non-nil **only while a session is running** — the `guard` (beep on nil) enforces
the "only during a session" decision, and routing through `TurnTaskBox` gives coalescing and
Stop-cancellation for free, identical to `onTurnEnd`/`onSilence`.

### 5. No Settings UI

The binding is fixed (⌥⌘J), so there is no Settings section in this scope. (A rebinding control —
either a hand-built recorder or a preset dropdown — is deferred; see Out of scope.)

### 6. No new dependency / build changes

Raw Carbon is part of the SDK, so `Package.swift` is unchanged and `build-app.sh` needs no
resource-bundle handling. `JarvisCore` stays Foundation-only; the Carbon import lives only in the
single `JarvisApp/Shortcuts/HotkeyController.swift` file.

## Data flow

```
⌥⌘J (global hot key — RegisterEventHotKey, fires even when Jarvis isn't frontmost)
  → Carbon event handler → HotkeyController.onRequestHint
  → AppDelegate: session running? → requestManualHint() → TurnTaskBox.run { driver.handleTrigger(.manualHint) }
  → CoachDriver.runTurn(.manualHint):
       capture screen (off-pool) → convo += .userImage
       brain.respond(convo, tools, toolChoice: .force("speak"), conversationId)   ← ONE trip
       → .speak(lines) → overlay.render(lines)  → hint on screen
```

## Error handling / edge cases

- **No session running:** `guard` ignores the press, `NSSound.beep()` signals it.
- **Screenshot fails (`capture()` returns nil):** proceed without the image; forced `speak` still
  produces a hint from transcript/conversation context. Logged as "screenshot failed".
- **Stop fires mid-capture:** the post-capture `Task.isCancelled` guard returns `.cancelled`
  before any overlay render — same protection the existing capture branch has.
- **Rapid double-press:** `TurnTaskBox` + `claimOrPend` coalesce into one pending follow-up turn
  rather than stacking, exactly like audio triggers.
- **Hotkey registration conflict:** if another app/the system already owns ⌥⌘J, `RegisterEventHotKey`
  fails and the hot key simply won't fire. With a fixed binding there's no in-app remedy yet; ⌥⌘J is
  an uncommon combo, and a rebinding UI is the deferred follow-up.

## Testing

- **Unit test (`Tests/JarvisCoreTests/Coach/`):** drive `CoachDriver.handleTrigger(.manualHint)`
  with the existing fake brain/screen/overlay fixtures and assert:
  1. `screen.capture()` is called by the driver (not the brain) — i.e. the image is injected, not
     tool-requested.
  2. `brain.respond` is called with `toolChoice == .force("speak")` and a message list containing a
     `.userImage`.
  3. The brain is called **once** (no `capture_screen` round trip) and the outcome is `.spoke`,
     with the overlay receiving the lines.
  4. Capture-failure variant: `screen.capture()` returns nil → still one call, still `.spoke`.
- **App-level (smoke checklist):** ⌥⌘J fires globally (even when another app is frontmost) and shows
  a hint while running; beeps when stopped. `JarvisApp` is not unit-tested per CLAUDE.md.

## Out of scope (YAGNI)

- Configurable hint *prompt text* (fixed for now).
- A rebinding UI for the shortcut (fixed ⌥⌘J for now — a recorder or preset dropdown can come later).
- Working without a session (auto-start / one-shot no-context path).
- Additional shortcuts beyond the hint trigger.
