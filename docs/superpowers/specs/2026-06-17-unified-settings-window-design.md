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

- `MenuBarController.swift` — menu items: Start/Stop, "Set OpenAI API Key…" (inline blocking modal,
  lines 97–142), optional "Open Log Viewer" (dev mode), counter, Quit.
- `ActivityViewer.swift` — standalone resizable `NSWindow` + `WKWebView`, **dev-mode only**, with
  live append, session picker, clear-history. Handles its own accessory→regular activation-policy
  switch.
- `OverlayPanel.swift` — `NSPanel` + `NSTextField`. Font size set once at line 39
  (`.systemFont(ofSize: 18, weight: .medium)`); background at line 23
  (`NSColor.black.withAlphaComponent(0.78)`). `sharingType = .none` (capture invisibility) is
  re-asserted in `show()`.
- No preferences storage exists. `Config.swift` holds compile-time tunables (not persisted).

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

| Unit | Module | Responsibility |
|------|--------|----------------|
| `SettingsSection` | JarvisApp | Protocol: tab title + content view + close hook |
| `SettingsWindow` | JarvisApp | Owns one `NSWindow` + `NSTabView`; builds one tab per section; owns the accessory→regular activation-policy switch on open/close. Takes `[SettingsSection]`. |
| `APIKeySection` | JarvisApp | Secure field + Save + status line. Writes to `KeychainSecretStore`, fires `onKeySaved`. (Logic moved out of `MenuBarController`.) |
| `OverlaySection` | JarvisApp | Text Size + Background Opacity sliders with live numeric readouts. Reads/writes `OverlayAppearance`; pushes live changes via an `OverlayAppearanceApplying` protocol (not a direct `OverlayPanel` dependency). |
| `ActivitySection` | JarvisApp | Dev-mode only. Wraps `ActivityViewer`'s vended content view. |
| `OverlayAppearance` | JarvisCore | `UserDefaults`-backed store for `fontSize` + `backgroundOpacity`, defaults sourced from `Config`. Clamps to valid ranges. |

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
  (JarvisCore, no AppKit.)
- `OverlayPanel` setters — font size and background alpha actually change; `sharingType == .none`
  survives a setter call. Extends `OverlayInvisibilityTests`.
- Existing `ActivityViewer`/`JarvisViewerTests` rendering tests stay green (logic untouched by the
  view-extraction refactor).

## Reuse summary

Reused as-is: `KeychainSecretStore`, `onKeySaved`, `Config`, all `ActivityViewer` rendering logic.
`MenuBarController` shrinks (modal dialog removed). New abstractions (`SettingsSection`,
`OverlayAppearance`, `OverlayAppearanceApplying`) are small; each section is independently testable.

## Out of scope (YAGNI)

- Continuous-vs-preset debate settled: continuous sliders.
- No per-session overrides, no theming beyond size/opacity, no font-family choice.
- Activity tab remains dev-mode-only (not exposed to normal users).
