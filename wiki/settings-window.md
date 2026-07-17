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
    var fillsTab: Bool { get }        // default: false — fixed-form panels pin to the top
}
```

The protocol is the only seam between `SettingsWindow` and the individual panels — sections have no
knowledge of the tab view or each other. `SettingsWindow` is the `NSTabViewDelegate`; on each tab
change it pairs `didResignActive()` on the outgoing section with `didBecomeActive()` on the incoming
one (and resigns the active section on window close). This lets a panel run side effects **only while
its tab is visible** rather than for the whole time the window is open.

### Window sizing

One user-resizable window size for every tab — 820×600 by default, minimum 560×460 (which keeps the
fixed-form panels fully visible). Switching tabs never resizes the window; whatever size the user
set stays. A section whose content should stretch with the window returns `fillsTab == true` (only
`ActivitySection` — the embedded log viewer); the fixed-form panels keep their designed frame,
wrapped so they pin to the top of the tab and center horizontally (AppKit's y-origin is the bottom,
so an unwrapped fixed-frame view would ride the bottom edge in a taller window).

### Sections

| Section class | Tab title | Always present | Description |
|---|---|---|---|
| `BrainSection` | "Brain" | yes | Everything that decides who answers a coaching turn, in one tab: the provider radios (OpenAI API / Claude Code / Codex CLI — see [Brain](#brain)), a per-provider model dropdown, the reasoning-effort dropdown (one global setting, mapped onto each provider's scale), and the OpenAI API-key controls (`APIKeyControls`: an `NSSecureTextField` that saves to an owner-only file and restarts the pipeline if already running). Takes effect on the next Start. |
| `OverlaySection` | "Overlay" | yes | Two groups, one per overlay surface — **Overlay Caption** (the transient on-screen tip) and **Overlay Box** (the persistent response history). Each has a header with an On/Off toggle (an `NSSwitch` + "On"/"Off" label) and a one-line description. When a surface is **on** it also shows its Text Size + Opacity sliders (with live readouts) and a live sample, **only while the Overlay tab is selected** (`didBecomeActive`/`didResignActive`); when **off**, its sliders and sample are hidden and the layout collapses. Persists via `OverlayAppearance`. |
| `DisplaySection` | "Screen" | yes | One dropdown — the capture scope: **Active window** (default) or one **Entire display** entry per connected display; persists via `ScreenCapturePreferences`. Applies to the next screenshot. |
| `ActivitySection` | "Activity" | yes | Embeds the `ActivityViewer` content view (`makeContentView()` / `teardown()`); `fillsTab == true` so the log stretches with the window. Its header carries **Evaluate** — one click sends the selected session's recorded LLM wire traffic (`brain-traffic.jsonl`) to the brain model at high effort for a context-engineering audit (`SessionEvaluator`), shown in a report window and saved as `eval-report.md` in the session dir. Only *finished* conversations qualify: the button is disabled while the selected session is the live, still-running one (a mid-session audit would judge half a story) and re-enables once Stop has drained any in-flight turn — the cancelled request's final traffic line must land before the audit reads the file. |

`AppDelegate` builds the section list at launch and passes it to `SettingsWindow`. All four sections
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

## Brain

The Brain tab owns the whole "who answers a coaching turn" decision, persisted through
`BrainPreferences` (UserDefaults).

**Provider.** Three radios (`BrainProvider`): the **OpenAI API** (metered by the key), or a locally
installed **Claude Code** / **Codex CLI** — in which case coaching turns are spawned as CLI
subprocesses and billed to the user's existing Claude / ChatGPT *subscription* instead of the key
(`CLIBrainClient`; see [architecture.md](./architecture.md#local-cli-brain-providers)). Installed
CLIs are auto-detected by `AgentCLIDetector` — pure file probes over $PATH + the CLIs' known install
dirs and on-disk auth markers, re-run every time the tab is shown, so no subprocess is spawned and
switching to a detected CLI is a single click. An uninstalled CLI shows as "not installed" and is
disabled; a detected-but-unconfirmed sign-in still selects (the auth probe is a hint — macOS
Keychain-only credentials are invisible to it).

**Model + effort.** A **Model** dropdown drawn from `BrainModelCatalog` per provider (OpenAI ids for
the API; CLI aliases like `sonnet` for the CLIs, plus a "CLI default" entry meaning "no model flag" —
for Codex that is its built-in default, since harness runs ignore the user's codex config). Each
provider remembers its own model. The **Reasoning
Effort** picker (`ReasoningEffort`: None / Low / Medium / High, default Low) is stored once and
applies uniformly to whichever provider is active — `CLIBrainClient` maps it onto each CLI's own
scale (Claude Code `--effort`, floor `low`; Codex `model_reasoning_effort`, floor `minimal`), so
model + effort behave the same way across all three providers.

**API key.** The OpenAI key controls (`APIKeyControls`) live at the bottom of the same tab because
the key is part of the same decision — and it stays **required regardless of provider**: realtime
voice transcription always runs on the OpenAI Realtime API. A CLI provider moves only the brain off
the key.

Reads are validated: a persisted model id no longer in that provider's catalog (or an unrecognized
provider/effort) falls back to the default rather than reaching the API. The transcription model is
deliberately **not** here — it's a separate field and code path (`Config.transcriptionModel`). The
values are read in `AppDelegate.start()` when the brain client is built, so a change takes effect on
the **next Start**, not mid-session — hence the caption on the tab.

All four selections persist via `BrainPreferences` —
`Sources/JarvisCore/Config/BrainPreferences.swift` is the single source for the UserDefaults keys,
defaults, and validation (the catalogs themselves live in
`Sources/JarvisCore/Brain/BrainModelCatalog.swift`).

## Capture Scope

What `capture_screen` shoots — one dropdown covering both the scope and, for entire-display
capture, the display: **Active window (recommended)** plus one **Entire display** entry per
connected display. Active-window mode reads the window server's single front-to-back z-order at capture time
(`WindowScopedScreenCapture` in `JarvisApp/Capture`, with the pick itself pure logic in Core's
`FrontWindowSelector`) and shoots the window the user last clicked or typed into — whichever
display it lives on — via `screencapture -l`, which reads the window's own backing image (clean
even when partially covered; `-o` omits the shadow). Jarvis's own windows, non-app layers (dock,
panels), and tiny layer-0 helper windows are skipped.

The window shot also gets an **on-device OCR sidecar**: `ScreenTextRecognizer` (Apple Vision,
`.accurate`, language correction off so code identifiers survive) recognizes the text and Core's
`RecognizedTextLayout` rebuilds reading order; `CoachDriver` sends it in the `capture_screen`
tool-result text beside the image, flagged as fallible, so the model reads exact code instead of
deciphering pixels. Nothing eligible on screen → fall back to a full shot of the **main display**;
fallback and entire-display captures skip OCR deliberately (a whole display's text would feed the
surrounding clutter back to the model as tokens).

The **Entire display** entries are named and numbered the way `screencapture -D` counts displays
(1 = the main display, the one with the menu bar; the dropdown enumerates `NSScreen.screens`, main
first, matching that order) and refresh when displays are plugged or unplugged while the tab is
visible. The chosen display persists as the 1-based `-D` index alongside the scope.

Both values are read **at capture time** (`WindowScopedScreenCapture` / `ScreenCaptureCLI`), so a
change applies to the very next screenshot with no restart. Reads are validated: an unrecognized
stored scope falls back to the default, a stored index < 1 clamps to the main display, and if the
chosen display no longer exists (the monitor was unplugged since it was chosen) `screencapture -D`
fails and `ScreenCaptureCLI` reshoots the main display rather than dropping the screenshot.
Fallbacks from active-window scope always capture the main display — a display index left over
from an old entire-display selection never steers them.

| Setting | Default | UserDefaults key |
|---|---|---|
| Capture scope | `activeWindow` | `screen.captureScope` |
| Entire-display display | `1` (main display) | `screen.captureDisplayIndex` |

## Key Files

| File | Role |
|---|---|
| `Sources/JarvisApp/Settings/SettingsSection.swift` | Protocol definition |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | Host window + tab view |
| `Sources/JarvisApp/Settings/BrainSection.swift` | Brain tab: provider + model + effort + key |
| `Sources/JarvisApp/Settings/APIKeyControls.swift` | The API-key rows embedded in the Brain tab |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Overlay-appearance tab |
| `Sources/JarvisApp/Settings/DisplaySection.swift` | Capture-scope tab (scope + display in one dropdown) |
| `Sources/JarvisApp/Settings/NSScreen+DisplayTitles.swift` | Display naming for the dropdown's entire-display entries |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Activity tab |
| `Sources/JarvisCore/Brain/BrainProvider.swift` | The three providers |
| `Sources/JarvisCore/Brain/AgentCLIDetector.swift` | CLI auto-detection (binary + auth markers) |
| `Sources/JarvisCore/Brain/BrainModelCatalog.swift` | Curated per-provider model lists (`BrainModel`) |
| `Sources/JarvisCore/Brain/ReasoningEffort.swift` | The four effort levels |
| `Sources/JarvisCore/Config/BrainPreferences.swift` | UserDefaults persistence + validation |
| `Sources/JarvisCore/Config/ScreenCapturePreferences.swift` | Capture scope + display persistence + clamping |
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
