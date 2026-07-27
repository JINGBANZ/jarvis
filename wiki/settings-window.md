# Settings Window — Design

> The unified Settings window consolidates all user-facing configuration into one non-modal panel
> reached via a single menu item. It replaces the old separate API-key dialog and the standalone
> activity-log window that were managed by `MenuBarController`.

## Entry Point

One menu item — **"Settings…"** — calls `SettingsWindow.show()`. The lightweight window and tab shell
are retained between opens. Section views are built only when selected and released on close, so
controls still start fresh without constructing hidden tabs before the window can appear.

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
set stays. A section whose content should stretch with the window returns `fillsTab == true`
(`BrainSection` and `ActivitySection`, whose scrollable content uses the available height); the other
fixed-form panels keep their designed frame,
wrapped so they pin to the top of the tab and center horizontally (AppKit's y-origin is the bottom,
so an unwrapped fixed-frame view would ride the bottom edge in a taller window).

### Sections

| Section class | Tab title | Always present | Description |
|---|---|---|---|
| `BrainSection` | "Brain" | yes | Everything that decides who answers a coaching attempt, in one tab: the primary provider/model, an ordered editable fallback list of provider/model targets, the reasoning-effort dropdown (one global setting, mapped onto each provider's scale), and the OpenAI API-key controls (`APIKeyControls`: an `NSSecureTextField` that saves to an owner-only file). Saving a key never restarts a live conversation: established Realtime sockets stay connected and use it on a later reconnect. Valid Brain changes take effect between coaching attempts while running, or on the next Start while stopped. |
| `OverlaySection` | "Overlay" | yes | Two groups, one per overlay surface — **Overlay Caption** (the transient on-screen tip) and **Overlay Box** (the persistent response history). Each has a header with an On/Off toggle (an `NSSwitch` + "On"/"Off" label) and a one-line description. When a surface is **on** it also shows its Text Size + Opacity sliders (with live readouts) and a live sample, **only while the Overlay tab is selected** (`didBecomeActive`/`didResignActive`); when **off**, its sliders and sample are hidden and the layout collapses. Persists via `OverlayAppearance`. |
| `DisplaySection` | "Screen" | yes | One dropdown — the capture scope: **Active window** (default) or one **Entire display** entry per connected display; persists via `ScreenCapturePreferences`. Applies to the next screenshot. |
| `ActivitySection` | "Activity" | yes | Embeds the `ActivityViewer` content view (`makeContentView()` / `teardown()`); `fillsTab == true` so the log stretches with the window. Its header shows the selected session's exact directory ID with **Copy ID**. A session without a report shows **Evaluate**: one click runs the sole `AgenticEvaluator` through a locally installed Claude Code / Codex CLI over the source checkout plus the complete session directory, writes owner-only `eval-report.md`, and opens it. While it runs the button shows **Evaluating…**; afterward it becomes **Open report**, which reopens the saved result without another model run. The agent reads the full unfiltered `jarvis-activity.jsonl` whenever it needs the user-visible sequence and correlates it with `brain-traffic.jsonl`, screenshots, and live source. `scripts/eval-session.sh` is a second launcher for this same Core evaluator, not another evaluation path. `EvalReportPage` renders the markdown as `eval-report.html`; **Copy as Markdown** hands the raw report to an agent chat. Evaluation, report opening, and history clearing stay disabled through the live coaching/teardown lifecycle. |

`AppDelegate` builds the section list at launch and passes it to `SettingsWindow`. All four tabs are
always present, but each tab's content is created lazily on first selection during that open.

## Activation-Policy Switch

`SettingsWindow` runs non-modal. Because the app normally runs as `.accessory` (no Dock icon),
`show()` promotes the activation policy to `.regular` so the window can become key and accept
paste/keyboard input. `windowWillClose(_:)` drops it back to `.accessory`. This is the same pattern
the old API-key dialog and activity viewer each learned independently — now consolidated in one
place. Initial Brain controls render from preferences and the latest cached CLI status immediately;
CLI status and capability subprocesses run away from the main actor and update those controls when
they finish, so their bounded timeouts cannot delay presentation.

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

The Brain tab owns the whole "who answers a coaching attempt" decision, persisted through
`BrainPreferences` (UserDefaults).

The tab is one vertically scrolling stack of three rounded groups: **Provider**, **Reasoning
effort**, then **Transcription**. The Provider group is one uninterrupted route: Primary and every
Fallback row share the same label / provider / model alignment, with ordering actions only on
fallbacks. There are no row dividers or permanent explanatory paragraphs. Fallback rows expand the
outer document instead of hiding inside a second scroll area. While coaching runs, a compact **In
use** marker exposes the runtime cursor without moving or rewriting any saved target.

**Primary.** The first row selects a provider and model: the **OpenAI API** (metered by the key), or a
locally installed **Claude Code** / **Codex CLI** — in which case coaching attempts are spawned as CLI
subprocesses and billed to the user's existing Claude / ChatGPT *subscription* instead of the key
(`CLIBrainClient`; see [architecture.md](./architecture.md#local-cli-brain-providers)). Installed
CLIs are auto-detected by `AgentCLIDetector`: binary discovery is a pure file probe over $PATH + the
known install dirs, while Claude sign-in uses its non-billing `auth status --json` command under a
short timeout because account metadata can outlive an expired OAuth session. Codex keeps using its
auth-file marker. Settings runs these probes asynchronously and keeps local-provider controls
selectable while the first result is pending. The provider menus then show **signed in**, **signed out**, or
**sign-in unknown**; a confirmed logout refuses Start, while an unavailable probe warns but does not
falsely claim logout. An actual CLI request can still fail after preflight.

Before first-time setup, Primary shows **Choose provider…**, its model menu is disabled, and **Add
fallback** is disabled. Selecting Primary creates the first valid route. Older installations that
already have the required transcription key retain the historical OpenAI default through a one-time
compatibility migration instead of being forced through setup again.

**Fallbacks.** Below the primary, an ordered list contains zero or more explicitly authorized
provider/model targets. **Add fallback** appends a row; each row has provider and model menus,
accessible `↑` / `↓` / `×` actions for Move Up, Move Down, and Remove. Rows are labelled **Fallback 1**,
**Fallback 2**, and so on, so visual order and failover order are identical. Exact duplicate targets
are rejected; a second model from the same provider is allowed as a deliberate separate target.
Edits still save immediately and apply on the next coaching attempt, but the normal UI does not
repeat that implementation detail.

The list is finite and follows the [ordered provider-route contract](./architecture.md#ordered-provider-route).
One target owns a complete coaching attempt. A provider error ends that attempt without replaying its
failed request; pending conversation schedules a new attempt with the newest finalized transcript.
Consecutive temporary/unknown failures advance when the active row reaches Core's code-owned failure
budget (see
[`BrainRouteSession.failuresPerTarget`](../Sources/JarvisCore/Coach/BrainRouteSession.swift)).
A failure proven permanent by the provider adapter exhausts the active row immediately, so the next
fresh attempt uses the next row; it never switches provider inside the failed attempt. A successful
attempt clears the active row's failure count but keeps that row active, including after fallback
activation. The runtime never returns to the primary or an exhausted row. When every row is
exhausted, coaching stops and Activity receives fixed typed route-exhausted copy; request details and
attempt counts remain in `jarvis-debug.log`.

Confirmed-missing or signed-out targets are disabled for new selection while editing; an existing
saved row stays visible so the user can repair or remove it. If a configured fallback becomes
unavailable after Start, activation skips it and moves forward without inventing provider requests
solely to consume the failure budget. Runtime movement through the route never changes the saved
list. Stop → Start begins at the saved primary again.

**Model + reasoning effort.** A **Model** dropdown is drawn from `BrainModelCatalog` per provider.
OpenAI API and Codex CLI share one concrete model list; Claude Code exposes the current concrete
release in each supported family. Each provider remembers its own model; without a valid preference,
the first entry in that provider's catalog is selected. The **Reasoning effort** picker
(`ReasoningEffort`: None / Low / Medium / High, default Low) is stored once and applies uniformly to
whichever provider is active. `CLIBrainClient` maps it onto Claude Code's `--effort` and Codex's
`model_reasoning_effort`; both CLI scales start at `low`, so None clamps to Low while the three shared
levels pass through.

**Transcription.** This group names the separate speech-to-text role explicitly so future
transcription providers can be added without conflating them with the brain route. It currently
shows **OpenAI API** as the sole provider and an **API key** row whose action is **Add API key** or
**Edit**—there is no persistent saved-status sentence. The key stays **required regardless of brain
provider** because realtime voice transcription runs on the OpenAI Realtime API. A CLI brain moves
only coaching off the key.

Reads are validated: a persisted primary model id no longer in that provider's catalog uses the
provider default without rewriting the invalid value, while invalid fallback rows are removed during
route normalization. An unrecognized provider/effort likewise uses its existing default rather than
reaching the API. The transcription model is deliberately **not** here — it's a separate field and
code path (`Config.transcriptionModel`). A running `CoachDriver` applies valid edits atomically at
the coaching-attempt boundary while transcript, client-managed history, audio pipeline, and session
logs continue unchanged. A provider, model, or route-order edit replaces the route for the next
attempt and resets the session-local cursor to the newly selected primary; this topology edit is the
only way to revisit a target that automatic failover left behind. The old active provider is not
retained as a hidden fallback; it remains available only when the user includes it in the new list.

A reasoning-effort edit instead rebuilds the clients at the current forward-only cursor and preserves
its failure counts. An attempt already in flight keeps its snapshotted client and remains
authoritative: its success or failure updates route health normally, and the new effort begins with
the next attempt. Saving the transcription API key likewise preserves route health, but refreshes
only OpenAI clients and never probes or replaces a CLI client.

A local-CLI target is preflighted first. A confirmed missing binary or signed-out account cannot
activate; the running route stays intact and Activity records fixed settings-not-applied copy.
Provider-specific partial tool-loop state from a failed attempt is discarded, while provider-neutral
pending conversation follows the newly installed route on its next attempt. While stopped, persisted
changes apply on the **next Start**.

All Brain choices persist via `BrainPreferences` —
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
| `Sources/JarvisApp/Settings/BrainSection.swift` | Minimal Brain tab composition: Provider + Reasoning effort + Transcription |
| `Sources/JarvisApp/Settings/BrainTargetRowView.swift` | Shared inline provider/model row for primary and fallback targets |
| `Sources/JarvisApp/Settings/ProviderRouteEditor.swift` | Unified Primary + ordered fallback card and persistence mutations |
| `Sources/JarvisApp/Settings/SettingsCardView.swift` | Resize callback at the grouped-card boundary |
| `Sources/JarvisApp/Settings/APIKeyControls.swift` | Transcription provider + collapsed API-key editor |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Overlay-appearance tab |
| `Sources/JarvisApp/Settings/DisplaySection.swift` | Capture-scope tab (scope + display in one dropdown) |
| `Sources/JarvisApp/Settings/NSScreen+DisplayTitles.swift` | Display naming for the dropdown's entire-display entries |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Activity tab |
| `Sources/JarvisCore/Brain/BrainProvider.swift` | The three providers |
| `Sources/JarvisCore/Brain/AgentCLIDetector.swift` | CLI binary discovery + bounded authentication-status detection |
| `Sources/JarvisCore/Brain/BrainModelCatalog.swift` | Curated per-provider model lists (`BrainModel`) |
| `Sources/JarvisCore/Brain/ReasoningEffort.swift` | The four effort levels |
| `Sources/JarvisCore/Diagnostics/AgenticEvaluator.swift` | Read-only Claude Code / Codex session audit invoked by Activity and `EvalPrep` |
| `Sources/JarvisCore/Config/BrainPreferences.swift` | UserDefaults persistence + route validation |
| `Sources/JarvisCore/Coach/CoachDriver.swift` | Between-attempt route application and attempt orchestration |
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
