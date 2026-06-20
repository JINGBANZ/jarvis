# Settings Window — Design

> The unified Settings window consolidates all user-facing configuration into one non-modal panel
> reached via a single menu item. It replaces the old separate API-key dialog and the standalone
> activity-log window that were managed by `MenuBarController`.

## Entry Point

One menu item — **"Settings…"** — calls `SettingsWindow.show()`. The window is rebuilt on each
open so every section starts fresh; re-opening while already visible brings it to the front without
rebuilding.

## Architecture

`SettingsWindow` hosts a list of `[SettingsSection]` values as `NSTabView` tabs. Each section is
self-contained: it declares a tab title, builds its own content view, and cleans up when the window
closes.

### `SettingsSection` protocol

```swift
@MainActor
protocol SettingsSection: AnyObject {
    var title: String { get }
    func makeView() -> NSView
    func didBecomeActive()            // default: no-op — this tab became visible
    func didResignActive()            // default: no-op — another tab chosen, or window closing
    func windowWillClose()            // default: no-op
    var prefersResizableWindow: Bool { get }   // default: false
}
```

The protocol is the only seam between `SettingsWindow` and the individual panels — sections have no
knowledge of the tab view or each other. `SettingsWindow` is the `NSTabViewDelegate`; on each tab
change it pairs `didResignActive()` on the outgoing section with `didBecomeActive()` on the incoming
one (and resigns the active section on window close). This lets a panel run side effects **only while
its tab is visible** rather than for the whole time the window is open.

### Per-tab window sizing

The simple panels are fixed-size (560×460); a section can opt into a larger, user-resizable window
by returning `prefersResizableWindow == true`. When such a tab becomes active, `SettingsWindow`
inserts `.resizable` into the style mask and grows the window to 820×600 (min 520×380); leaving the
tab restores the fixed compact size. Only `ActivitySection` opts in — the log benefits from room and
resizing; the API-key and overlay panels stay compact.

### Sections

| Section class | Tab title | Always present | Description |
|---|---|---|---|
| `APIKeySection` | "API Key" | yes | `NSSecureTextField` to paste the OpenAI key; saves to an owner-only file on "Save", restarts the pipeline if already running. |
| `OverlaySection` | "Overlay" | yes | Text-size and background-opacity sliders with live readouts; persists via `OverlayAppearance`; shows the sample-overlay live preview **only while the Overlay tab is selected** (`didBecomeActive`/`didResignActive`). |
| `ActivitySection` | "Activity" | dev mode only | Embeds the `ActivityViewer` content view (`makeContentView()` / `teardown()`); `prefersResizableWindow == true` so the log gets a larger, resizable window. |

`AppDelegate` builds the section list at launch and passes it to `SettingsWindow`. `ActivitySection`
is appended only when `--dev` is passed.

## Activation-Policy Switch

`SettingsWindow` runs non-modal. Because the app normally runs as `.accessory` (no Dock icon),
`show()` promotes the activation policy to `.regular` so the window can become key and accept
paste/keyboard input. `windowWillClose(_:)` drops it back to `.accessory`. This is the same pattern
the old API-key dialog and activity viewer each learned independently — now consolidated in one
place.

## Overlay Appearance

Overlay appearance is persisted through `OverlayAppearance` (UserDefaults) with defaults and valid
ranges defined in `Config`:

| Property | Default | Range | UserDefaults key |
|---|---|---|---|
| Font size | 18 pt | 12–32 pt | `overlay.fontSize` |
| Background opacity | 0.78 (78%) | 0.40–1.00 (40–100%) | `overlay.backgroundOpacity` |

`OverlaySection` applies changes live to the overlay via the `OverlayAppearanceApplying` protocol
(`setFontSize(_:)` / `setBackgroundOpacity(_:)` / `showAppearancePreview(_:)`), with no direct
dependency on `OverlayPanel`. Changes are round-tripped through `OverlayAppearance` so they survive
an app relaunch.

The sample-overlay preview is shown only while the Overlay tab is selected (toggled from
`didBecomeActive`/`didResignActive`, not from `makeView`/`windowWillClose`). `showAppearancePreview(_:)`
re-asserts capture exclusion via the counted `reassertCaptureExclusion()` helper inside `OverlayPanel`
so the preview stays hidden from screen capture — same defense-in-depth as the coaching display path —
and its off-path only hides the panel when a preview is actually up, so closing/leaving the tab never
tears down a live coaching tip. The `setFontSize`/`setBackgroundOpacity` setters only change appearance
and don't touch `sharingType`. See [overlay-invisibility.md](./overlay-invisibility.md).

## Key Files

| File | Role |
|---|---|
| `Sources/JarvisApp/Settings/SettingsSection.swift` | Protocol definition |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | Host window + tab view |
| `Sources/JarvisApp/Settings/APIKeySection.swift` | API-key tab |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Overlay-appearance tab |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Dev-mode activity tab |
| `Sources/JarvisCore/Config/Config.swift` | `overlayFontSizeRange`, `overlayOpacityRange`, defaults |
| `Sources/JarvisCore/Overlay/OverlayAppearance.swift` | UserDefaults persistence |
| `Sources/JarvisOverlay/OverlayPanel.swift` | `OverlayAppearanceApplying` conformance |

## Related Pages

- [overlay-invisibility.md](./overlay-invisibility.md) — capture exclusion re-assert during preview
- [build-and-run.md](./build-and-run.md) — the embedded dev-mode activity log
