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
| `OverlaySection` | "Overlay" | yes | Two groups, one per overlay surface — **Overlay Caption** (the transient on-screen tip) and **Overlay Box** (the persistent response history). Each has a header with an On/Off toggle (an `NSSwitch` + "On"/"Off" label) and a one-line description. When a surface is **on** it also shows its Text Size + Opacity sliders (with live readouts) and a live sample, **only while the Overlay tab is selected** (`didBecomeActive`/`didResignActive`); when **off**, its sliders and sample are hidden and the layout collapses. Persists via `OverlayAppearance`. |
| `DisplaySection` | "Screen" | yes | One dropdown listing the connected displays — which one `capture_screen` screenshots; persists via `ScreenCapturePreferences`. Applies to the next screenshot. |
| `BrainModelSection` | "Brain" | yes | Two dropdowns — the brain (LLM) model and the reasoning effort applied to it; persists via `BrainPreferences`. Takes effect on the next Start. |
| `ActivitySection` | "Activity" | yes | Embeds the `ActivityViewer` content view (`makeContentView()` / `teardown()`); `prefersResizableWindow == true` so the log gets a larger, resizable window. |

`AppDelegate` builds the section list at launch and passes it to `SettingsWindow`. All five sections
are always present.

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
| Caption enabled | off | on/off | `overlayCaption.enabled` |
| Caption font size | 18 pt | 12–32 pt | `overlayCaption.fontSize` |
| Caption background opacity | 0.78 (78%) | 0.40–1.00 (40–100%) | `overlayCaption.backgroundOpacity` |
| Box enabled | on | on/off | `overlayBox.enabled` |
| Box font size | 14 pt | 12–32 pt | `overlayBox.fontSize` |
| Box opacity | 1.00 (100%) | 0.40–1.00 (40–100%) | `overlayBox.opacity` |

The two surfaces default opposite ways — the caption **off**, the box **on** — so a first run shows
the durable history rather than a flashing caption. `AppDelegate` applies both enabled flags at launch.

`OverlaySection` applies changes live through two protocols, with no direct dependency on the AppKit
panels: `OverlayCaptionApplying` (`setFontSize` / `setBackgroundOpacity` / `setEnabled` /
`showAppearancePreview`, conformed by `OverlayCaptionPanel`) and `OverlayBoxApplying` (`setFontSize` /
`setOpacity` / `setEnabled` / `showAppearancePreview`, conformed by `OverlayBoxPanel`). All values
round-trip through `OverlayAppearance` so they survive an app relaunch.

`setEnabled(false)` on the caption suppresses coaching tips (dropping any in-flight/queued tip); on
the box it simply hides the window. A surface's live sample is shown only while the Overlay tab is
selected **and that surface is on** — `didBecomeActive` previews each surface for its enabled state,
and flipping a toggle shows/hides that surface's sample (and collapses/expands its sliders via
`relayout()`) live. Each panel's `showAppearancePreview(_:)` re-asserts capture exclusion so the
preview stays hidden from screen capture — same defense-in-depth as the coaching display path. The
box's preview shows sample
text without disturbing the real log and restores the box's **user-intended** visibility on close (it
tracks intent separately from `panel.isVisible` so the setting can't desync). The plain setters
(`setFontSize`/`setBackgroundOpacity`/`setOpacity`) only change appearance and don't touch
`sharingType`. See [overlay-invisibility.md](./overlay-invisibility.md).

## Brain Model

The brain (LLM) model and its reasoning effort are user-selectable, persisted through
`BrainPreferences` (UserDefaults). Two independent dropdowns: a **Model** picker drawn from
`BrainModelCatalog` — the curated, code-owned list of OpenAI brain models (the single source of truth,
bumped by a one-line edit when OpenAI ships a new one) — and a **Reasoning Effort** picker over the
fixed `ReasoningEffort` levels (None / Low / Medium / High, default Low). The effort is stored
independently of the model, so it's set once and carries across model changes.

Reads are validated: a persisted model id no longer in the catalog (or an unrecognized effort) falls
back to the default rather than reaching the API. The transcription model is deliberately **not**
here — it's a separate field and code path (`Config.transcriptionModel`). Both values are read in
`AppDelegate.start()` when the brain client is built, so a change takes effect on the **next Start**,
not mid-session — hence the caption on the tab.

| Setting | Default | Source of truth | UserDefaults key |
|---|---|---|---|
| Brain model | `gpt-5.5` | `BrainModelCatalog` | `brain.model` |
| Reasoning effort | `low` | `ReasoningEffort` | `brain.reasoningEffort` |

## Capture Scope

What `capture_screen` shoots: the **active window** (default) or the **entire selected display**.
Active-window mode reads the window server's single front-to-back z-order at capture time
(`WindowScopedScreenCapture` in `JarvisApp/Capture`, with the pick itself pure logic in Core's
`FrontWindowSelector`) and shoots the window the user last clicked or typed into — whichever
display it lives on — via `screencapture -l`, which reads the window's own backing image (clean
even when partially covered; `-o` omits the shadow). Jarvis's own windows, non-app layers (dock,
panels), and tiny layer-0 helper windows are skipped.

The window shot also gets an **on-device OCR sidecar**: `ScreenTextRecognizer` (Apple Vision,
`.accurate`, language correction off so code identifiers survive) recognizes the text and Core's
`RecognizedTextLayout` rebuilds reading order; `CoachDriver` sends it in the `capture_screen`
tool-result text beside the image, flagged as fallible, so the model reads exact code instead of
deciphering pixels. Nothing eligible on screen → fall back to the entire-display capture below;
fallback and entire-display captures skip OCR deliberately (a whole display's text would feed the
surrounding clutter back to the model as tokens).

Persisted through `ScreenCapturePreferences` and read at capture time like the display index; an
unrecognized stored value falls back to the default.

| Setting | Default | UserDefaults key |
|---|---|---|
| Capture scope | `activeWindow` | `screen.captureScope` |

## Capture Display

Which display **entire-display captures** use — the Entire display scope and every fallback from
the active-window scope — is user-selectable, persisted through
`ScreenCapturePreferences` (UserDefaults) as the **1-based index `screencapture -D` uses** (1 = the
main display, the one with the menu bar). The dropdown enumerates `NSScreen.screens` — main display
first, matching `screencapture`'s numbering — and refreshes when displays are plugged or unplugged
while the tab is visible.

Unlike the brain settings, the selection is read **at capture time** (`ScreenCaptureCLI`), so a
change applies to the very next screenshot with no restart. Reads are validated twice: a stored
value < 1 clamps to the main display, and if the selected display no longer exists (the monitor was
unplugged since it was chosen) `screencapture -D` fails and `ScreenCaptureCLI` falls back to a plain
main-display capture rather than dropping the screenshot.

A user-initiated **Start with more than one display connected also prompts** for the screen to watch
(`DisplayPicker`: an alert with the same dropdown, pre-selected to the persisted choice; Cancel
aborts the Start untouched) — so a laptop-vs-monitor session never silently coaches from the wrong
screen. One display → no prompt; an in-place restart (e.g. re-saving the API key while running)
never prompts. The prompt writes through the same `ScreenCapturePreferences`, so it and the
Settings tab are one setting.

| Setting | Default | UserDefaults key |
|---|---|---|
| Capture display | `1` (main display) | `screen.captureDisplayIndex` |

## Key Files

| File | Role |
|---|---|
| `Sources/JarvisApp/Settings/SettingsSection.swift` | Protocol definition |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | Host window + tab view |
| `Sources/JarvisApp/Settings/APIKeySection.swift` | API-key tab |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Overlay-appearance tab |
| `Sources/JarvisApp/Settings/DisplaySection.swift` | Capture-display tab |
| `Sources/JarvisApp/Settings/DisplayPicker.swift` | Start-time display prompt (>1 display) |
| `Sources/JarvisApp/Settings/NSScreen+DisplayTitles.swift` | Shared display naming for the tab + prompt |
| `Sources/JarvisApp/Settings/BrainModelSection.swift` | Brain model + reasoning-effort tab |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Activity tab |
| `Sources/JarvisCore/Coach/BrainModelCatalog.swift` | Curated model list (`BrainModel`) |
| `Sources/JarvisCore/Coach/ReasoningEffort.swift` | The four effort levels |
| `Sources/JarvisCore/Config/BrainPreferences.swift` | UserDefaults persistence + validation |
| `Sources/JarvisCore/Config/ScreenCapturePreferences.swift` | Capture-display persistence + clamping |
| `Sources/JarvisCore/Screen/ScreenCapture.swift` | `ScreenCaptureCLI` — reads the selection at capture time, falls back to the main display |
| `Sources/JarvisCore/Config/Config.swift` | `overlayCaption*`/`overlayBox*` size + opacity ranges, enabled + appearance defaults |
| `Sources/JarvisCore/Overlay/OverlayAppearance.swift` | UserDefaults persistence; `OverlayCaptionApplying` + `OverlayBoxApplying` protocols |
| `Sources/JarvisCore/Overlay/BroadcastOverlay.swift` | Fans one `render` out to the caption + box |
| `Sources/JarvisOverlay/OverlayCaptionPanel.swift` | The Overlay Caption; `OverlayCaptionApplying` conformance |
| `Sources/JarvisOverlay/OverlayBoxPanel.swift` | The Overlay Box; `OverlayBoxApplying` conformance |
| `Sources/JarvisOverlay/NSPanel+CaptureExclusion.swift` | Shared `sharingType = .none` helper for both panels |

## Related Pages

- [overlay-invisibility.md](./overlay-invisibility.md) — capture exclusion re-assert during preview
- [build-and-run.md](./build-and-run.md) — the embedded activity log
