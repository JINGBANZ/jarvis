# Unified Settings Window — Design

> Build-time spec (lives outside the wiki per `wiki/CLAUDE.md` rule 7). Once shipped, fold the
> final state into the relevant wiki design pages and add a one-line entry to `status.md`, then
> delete this file.

## Goal

Add the ability to adjust the overlay's **text size** and **background opacity**, and consolidate
the app's scattered windows (API-key dialog, activity log) into a **single Settings window** opened
from one menu item. Maximize reuse and keep each panel a self-contained, independently testable
unit.

## Current state

> Paths reflect the subsystem layout from `Organize sources by subsystem` (#11). Subfolders under
> `Sources/<Target>/` are organization only — SPM globs each target into one module, so adding files
> or subfolders needs no `Package.swift` edit.

- `Sources/JarvisApp/MenuBar/MenuBarController.swift` — menu items: Start/Stop, "Set OpenAI API
  Key…" (inline blocking modal), optional "Open Log Viewer" (dev mode), counter, Quit.
- `Sources/JarvisApp/Viewer/ActivityViewer.swift` — standalone resizable `NSWindow` + `WKWebView`,
  **dev-mode only**, with live append, session picker, clear-history. Handles its own
  accessory→regular activation-policy switch.
- `Sources/JarvisApp/App/AppDelegate.swift` — wiring hub: creates the overlay + menu bar, owns the
  pipeline lifecycle.
- `Sources/JarvisOverlay/OverlayPanel.swift` — `NSPanel` + `NSTextField`. Font size set once
  (`.systemFont(ofSize: 18, weight: .medium)`); background (`NSColor.black.withAlphaComponent(0.78)`).
  `sharingType = .none` (capture invisibility) is re-asserted in `show()`.
- `Sources/JarvisCore/Config/Config.swift` — compile-time tunables (not persisted). No preferences
  storage exists anywhere yet.

## Architecture

A `SettingsSection` protocol is the decoupling seam. `SettingsWindow` is a thin host that knows
nothing about the individual panels.

```swift
@MainActor protocol SettingsSection {
    var title: String { get }     // tab label
    func makeView() -> NSView     // the panel's content
    func windowWillClose()        // cleanup hook; default no-op via extension
}
```

### Components

New UI units live in a new `Sources/JarvisApp/Settings/` subfolder (a new subsystem — settings is
distinct from `MenuBar/` and `Viewer/`). The Foundation-only appearance store lives in
`Sources/JarvisCore/Overlay/` alongside the existing overlay text model and `OverlayRendering`
protocol — it must stay AppKit-free so it's unit-testable in `JarvisCore`.

| Unit | Path | Responsibility |
|------|------|----------------|
| `SettingsSection` | `JarvisApp/Settings/SettingsSection.swift` | Protocol: tab title + content view + close hook (default no-op via extension). |
| `SettingsWindow` | `JarvisApp/Settings/SettingsWindow.swift` | Owns one `NSWindow` + `NSTabView`; builds one tab per section; owns the accessory→regular activation-policy switch on open/close. Takes `[SettingsSection]`. |
| `APIKeySection` | `JarvisApp/Settings/APIKeySection.swift` | Secure field + Save + status line. Writes to `KeychainSecretStore`, fires `onKeySaved`. (Logic moved out of `MenuBarController`.) |
| `OverlaySection` | `JarvisApp/Settings/OverlaySection.swift` | Text Size + Background Opacity sliders with live numeric readouts. Reads/writes `OverlayAppearance`; pushes live changes via an `OverlayAppearanceApplying` protocol (not a direct `OverlayPanel` dependency). |
| `ActivitySection` | `JarvisApp/Settings/ActivitySection.swift` | Dev-mode only. Wraps `ActivityViewer`'s vended content view. |
| `OverlayAppearance` | `JarvisCore/Overlay/OverlayAppearance.swift` | `UserDefaults`-backed store for `fontSize` + `backgroundOpacity`, defaults sourced from `Config`. Clamps to valid ranges. Foundation-only. |
| `OverlayAppearanceApplying` | `JarvisCore/Overlay/OverlayAppearance.swift` | Protocol (`setFontSize`/`setBackgroundOpacity`) the overlay conforms to, so `OverlaySection` depends on an abstraction, not `OverlayPanel`. AppKit-free signatures. |

### Changes to existing units

- **`OverlayPanel`** — add `setFontSize(_:)` and `setBackgroundOpacity(_:)`; preserve
  `sharingType = .none`. Add `OverlayPanel: OverlayAppearanceApplying` conformance.
- **`ActivityViewer`** — refactor to **vend its content `NSView`** (header + `WKWebView`) instead of
  owning an `NSWindow`. All WKWebView/session/live-append/clear-history logic unchanged. Window
  ownership + activation-policy code moves to `SettingsWindow`. Live-row `detach()` cleanup runs from
  the section's `windowWillClose()`.
- **`MenuBarController`** — replace "Set OpenAI API Key…" and "Open Log Viewer" with one
  **"Settings…"** item firing `onOpenSettings`. Remove the inline modal API-key dialog code; the
  controller returns to pure menu duties (Start/Stop, counter, Quit, status title).
- **`Config`** — add overlay-appearance default constants (`overlayFontSize = 18`,
  `overlayBackgroundOpacity = 0.78`) plus the allowed ranges used for clamping.
- **`AppDelegate`** — create the `[SettingsSection]` (Activity only in dev mode) and `SettingsWindow`;
  wire `onOpenSettings`. Load `OverlayAppearance` at launch and apply to the `OverlayPanel` after
  creation (~line 50).

## Behavior

- **One window, tabbed.** Top-tabbed `NSTabView`. "General" always present (API Key + Overlay
  Appearance sections). "Activity" tab present only in dev mode.
- **Non-modal.** `SettingsWindow` switches the app to `.regular` while open (so the secure field can
  become first responder and accept paste) and back to `.accessory` on close — the lesson both old
  windows learned. No blocking `runModal`.
- **Live preview.** Moving a slider applies immediately to the overlay via
  `OverlayAppearanceApplying`. Because the overlay only renders when there is coaching text,
  `OverlaySection` shows a sample overlay ("Sample overlay text") while the window is open and clears
  it on close, so size/opacity changes are visible in real time.
- **Persistence.** Slider changes write through to `OverlayAppearance` (UserDefaults). Values reload
  and apply on next launch.

### Ranges

| Setting | Range | Default |
|---------|-------|---------|
| Text size | 12–32 pt | 18 pt |
| Background opacity | 0.40–1.00 | 0.78 |

## Testing

- `OverlayAppearance` — persistence round-trip; clamping out-of-range values; defaults from `Config`.
  New `Tests/JarvisCoreTests/Overlay/OverlayAppearanceTests.swift` (no AppKit; uses an isolated
  `UserDefaults(suiteName:)`).
- `OverlayPanel` setters — font size and background alpha actually change; `sharingType == .none`
  survives a setter call. Extends `Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift`.
- Existing `Tests/JarvisViewerTests/` rendering tests stay green (logic untouched by the
  view-extraction refactor).

## Reuse summary

Reused as-is: `KeychainSecretStore`, `onKeySaved`, `Config`, all `ActivityViewer` rendering logic.
`MenuBarController` shrinks (modal dialog removed). New abstractions (`SettingsSection`,
`OverlayAppearance`, `OverlayAppearanceApplying`) are small; each section is independently testable.

## Out of scope (YAGNI)

- Continuous-vs-preset debate settled: continuous sliders.
- No per-session overrides, no theming beyond size/opacity, no font-family choice.
- Activity tab remains dev-mode-only (not exposed to normal users).
