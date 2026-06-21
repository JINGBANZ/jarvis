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
| Hotkey mechanism | **`KeyboardShortcuts` SPM package** (Sindre Sorhus). Industry standard; wraps Carbon `RegisterEventHotKey`, so **no Accessibility/TCC permission and no permission dialog**. Swift 6-compatible. |
| Customizable? | **Yes — a recorder field in Settings.** The recorder (press-any-combo) is the part that's tedious to hand-build, which is what justifies the dependency. Default binding **⌥⌘J**. |
| Synthetic message | **Fixed generic prompt** (hard-coded, not configurable). |
| Force a reply? | **Yes — force the `speak` tool** (`ToolChoice.force("speak")`) so a keypress always yields a visible hint. |

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

### 3. Global hotkey — `Sources/JarvisApp/MenuBar/` (or a new `Shortcuts/` subfolder)

- **`HintShortcut.swift`** — declares the shortcut name + default:

  ```swift
  import KeyboardShortcuts
  extension KeyboardShortcuts.Name {
      static let requestHint = Self("requestHint", default: .init(.j, modifiers: [.command, .option]))
  }
  ```

- **`HotkeyController.swift`** — a tiny `@MainActor` type that registers the handler and exposes a
  callback, mirroring how `MenuBarController` exposes `onStart`/`onStop`:

  ```swift
  @MainActor final class HotkeyController {
      var onRequestHint: (() -> Void)?
      init() {
          KeyboardShortcuts.onKeyUp(for: .requestHint) { [weak self] in self?.onRequestHint?() }
      }
  }
  ```

  (`onKeyUp` avoids auto-repeat from a held combo; `onKeyDown` is the alternative.)

### 4. Wiring — `Sources/JarvisApp/App/AppDelegate.swift`

In `applicationDidFinishLaunching`, alongside the existing menu-callback wiring, construct the
`HotkeyController` and route its callback through the same `TurnTaskBox` the transcriber callbacks
use:

```swift
hotkeys = HotkeyController()
hotkeys.onRequestHint = { [weak self] in
    guard let self, let turns = self.turns else { NSSound.beep(); return }  // no live session
    turns.run { await self.driver?.handleTrigger(.manualHint) }
}
```

`turns` (and a stored `driver`) are non-nil only while a session is running, so the
`guard` cleanly enforces the "only during a session" decision. Routing through `TurnTaskBox` gives
coalescing and Stop-cancellation for free, identical to `onTurnEnd`/`onSilence`.

> Minor: today `AppDelegate` stores the transcribers/capture/`turns` but not the `driver`. We
> need a reference to the live `driver` (or a stored closure that calls it). Add a `driver`
> property set in `start()` and cleared in `stop()`, matching the existing session-state fields.

### 5. Settings recorder — `Sources/JarvisApp/Settings/ShortcutsSection.swift`

A new `SettingsSection` ("Shortcuts" tab) hosting `KeyboardShortcuts.RecorderCocoa` (AppKit) for
`.requestHint`. The recorder persists to `UserDefaults` and warns on conflicts automatically; no
extra config plumbing. Register the section in the array passed to `SettingsWindow` in
`AppDelegate` (next to the API-key / overlay / brain-model sections).

### 6. Package — `Package.swift`

Add the dependency and attach it to the executable target only:

```swift
.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
// …
.executableTarget(
    name: "JarvisApp",
    dependencies: ["JarvisCore", "JarvisOverlay", "CJarvisAEC",
                   .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]
)
```

`JarvisCore` stays Foundation-only and dependency-free — the package never reaches it.

## Data flow

```
⌥⌘J (global, no session-focus needed)
  → KeyboardShortcuts handler → HotkeyController.onRequestHint
  → AppDelegate: session running? → TurnTaskBox.run { driver.handleTrigger(.manualHint) }
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
- **Hotkey registration conflict:** `KeyboardShortcuts` surfaces conflicts in the recorder; a
  system-claimed default just won't fire — the user rebinds in Settings.

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
- **App-level (smoke checklist):** hotkey fires only while running; beep when stopped; recorder in
  Settings rebinds the shortcut and it persists across relaunch. `JarvisApp` is not unit-tested per
  CLAUDE.md.

## Out of scope (YAGNI)

- Configurable hint *prompt text* (fixed for now).
- Working without a session (auto-start / one-shot no-context path).
- Additional shortcuts beyond the hint trigger (the section is structured to grow, but we add one).
