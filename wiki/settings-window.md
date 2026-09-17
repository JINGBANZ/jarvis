# Settings Window — Design

> The unified Settings window consolidates all user-facing configuration into one non-modal window
> reached via a single menu item. It opens on a hub drawn as Jarvis's head: the brain, ears, eye, and
> mouth open the pages that configure them, and a row of buttons opens the rest.

## Entry Point

One menu item — **"Settings"** — calls `SettingsWindow.show()`. The window always opens on the hub.
The window shell is kept between opens. The hub and each page are built on their first visit during
an open, kept while the window stays open, and released on close, so controls start fresh and no
hidden page is built before the window can appear.

## Architecture

`SettingsWindow` holds one `SettingsHome` (the hub) and the `[SettingsSection]` pages keyed by
`SettingsDestination`, and shows one of them at a time in a plain container view. Each section is
self-contained: it names its destination, builds its own page, and cleans up when the window closes.
A hub replaces a tab strip because the head is the map of what each page configures. The container
is a plain view rather than a tabless `NSTabView` so a page change can hold the outgoing and incoming
views on screen together while it animates ([Motion](#motion)).

### `SettingsSection` protocol

```swift
@MainActor
protocol SettingsSection: AnyObject {
    var destination: SettingsDestination { get }
    func makePage() -> SettingsPageView
    func didBecomeActive()            // default: no-op — this page became the visible one
    func didResignActive()            // default: no-op — another page chosen, or window closing
    func windowWillClose()            // default: no-op
}
```

The protocol is the only seam between `SettingsWindow` and the individual pages — sections know
nothing about the hub, the window, or each other. On every navigation the window pairs
`didResignActive()` on the outgoing page with `didBecomeActive()` on the incoming one, and resigns
the visible page on close; the hub gets the same pair. This lets a page run side effects **only while
it is visible** rather than for the whole time the window is open. A section returns a typed
`SettingsPageView`, so the window attaches the back action without inspecting the page.

### Navigation

`SettingsDestination` names every page, with `home` for the hub, and is the one place the four head
parts map to their pages. The hub opens pages; every page header has a **‹ JARVIS** back button,
also bound to ⌘[. Esc closes the window. A page notice's **Open Connections** button moves straight
to Connections. Pages are added to and removed from the window while it is open, so the window
recalculates its key view loop automatically rather than each view wiring `nextKeyView`.

### Window sizing

One user-resizable window size for every page — 820×600 by default, minimum 560×460. Navigating
never resizes the window; whatever size the user set stays. Every page uses `SettingsPageView`, so
page margins and headers expand consistently while cards and trailing controls adapt to the
available width. Brain, Ear, Connections, and Tools stack their variable-height cards in
`SettingsCardStack`; Mouth, Skills, Shortcuts, and the hub scroll their own documents; Eye and
Activity use the page shell without an outer scroll view.

### Shared visual system

The pages share these AppKit primitives rather than styling their controls independently:

- `SettingsTheme` owns every Settings color: purple for structure, teal for what is on, selected, or
  live, amber for what needs the user. Each color resolves per appearance, including the Increase
  Contrast appearances, where card lines draw at full strength, so every view follows light and dark
  mode without observing the change.
- `SettingsBackgroundView` draws the radial backdrop behind the hub and every page.
- `SettingsPageView` owns the page header: the back button (`SettingsBackButton`), the part's mini
  robot on the four head pages, the uppercase title, one-line summary, and an optional chip that
  says when edits apply or, in teal, what is live. It also owns an optional amber notice and the
  outer margins.
- `SettingsCardView` owns the opaque rounded group and its tracked uppercase header.
- `SettingsRowView` owns label/help typography, row height, separators, and responsive trailing
  control alignment.
- `SettingsCardStack` owns a top-aligned scrolling column of fixed-height cards that keeps the
  reader's distance from the top when a card changes height, and `SettingsCalloutView` owns the info
  or warning note under a card.
- `SettingsStyle` owns the spacing, corner radius, and sizing tokens.

Native controls (pop-up menus, switches, sliders, segmented controls, and buttons) keep the macOS
look and the system accent color. Restyling AppKit controls is fragile across macOS releases, and a
card reads better with one "on" color than with a teal switch beside an accent-colored slider. Cards
are opaque, so Reduce Transparency needs no special case.

Sections still own their behavior and concrete controls. The visual primitives do not read or write
preferences, start probes, load Activity, or know about another page. Activity keeps its `WKWebView`
lazy lifecycle and its own toolbar; its adaptive light/dark feed is framed by the same page and card
chrome.

Page copy speaks as Jarvis, in the first person ("Who does my thinking, and how hard I think.").
State labels stay functional ("Signed in", "Checking…").

## Hub

`RobotHub.state(for:)` in JarvisCore is the hub's one decision point. It turns one `RobotHubInputs`
value (the saved settings the hub summarizes, the keys, grants, and sign-ins in `RobotReadiness`,
and the brain the running session is using) into one `RobotHubState`: every slot's value and
detail line, its tone, the Brain slot's effort bars, each part's status, the readiness meter, and
whether the robot looks live. `RobotPartSummaries` writes the saved-setting lines and `RobotHealth`
holds the status rules. In the app, `SettingsHubModel` is the one reader of those inputs and
publishes the state; `SettingsHome` and its views only draw it. The decisions live in Core because
JarvisApp has no unit-test target.

**The head.** `RobotHeadView` draws Jarvis's head in code from the approved prototype's design
space, both as the hub's large robot and as the small badge on each head page. It is drawn rather
than shipped as images because the build has no asset catalog. Its four parts (`RobotPart`) open
their pages: the brain dome opens **Brain**, the ears **Ear**, the visor **Eye**, and the mouth
**Mouth**. The drawing is not an accessibility element; the slots are the accessible path to the
same pages.

**Slots.** Each part has a slot (`RobotSlotView`) with its icon, name, current value, and a short
detail line. Brain shows the primary model and `VIA <PROVIDER>`, with three bars lit for the
reasoning effort (none for None, three for High). Ear shows the transcription provider and short
model name and the languages it expects. Eye shows the capture scope and whether Chrome text is on.
Mouth shows which overlays are on. Slots are keyboard-focusable buttons (Space or Return opens) that
VoiceOver reads as "<Part> settings" with the slot's value and detail. Hovering or focusing a slot
lights its part of the head and its connector; hovering a part lights its slot.

**Dock.** Five chamfered buttons (`HomeDockButton`) under the head open **Connections**, **Tools**,
**Skills**, **Shortcuts**, and **Activity**.

**Layouts.** A window at least 780×560 shows the prototype's stage: the robot in the middle, Brain
and Ear slots on the left, Eye and Mouth on the right, connector lines to their parts, and the dock
along the bottom. A smaller window shows one scrolling column: a smaller robot, the slots in a 2×2
grid, and the dock wrapping into rows. Tab order reads Brain, Eye, Ear, Mouth, then the dock, in
both layouts.

**Animation.** The robot blinks, pulses its brain circuits, and moves its mouth only while the hub is
showing, the window is key and visible, and Reduce Motion is off; otherwise it holds the last frame
it drew. Its clocks advance only while it runs, so pausing, resuming, or switching to the live look
never makes the pose jump.

### Status

Each slot has a status light, teal when the part is ready and amber when it needs the user, and the
hub header shows a four-segment readiness meter in part order that reads **SYSTEMS READY 4/4** or
**NEEDS YOU n/4**. A part that needs the user turns its slot amber and replaces the slot's detail
with the reason. The rules judge saved settings and grants the way a Start would meet them, and name
only what Settings can fix or explain:

- **Brain** needs an OpenAI key whenever any target in the route uses the OpenAI API and no key is
  saved. Start refuses in that case, so the hub asks for the key rather than promising to skip that
  target. Otherwise Brain needs attention when the primary is a subscription proven signed out; the
  notice says whether the next brain in the route will answer instead, or whether none can.
- **Ear** needs its transcription provider's own key first, then microphone access.
- **Eye** needs Screen Recording.
- **Mouth** needs at least one of the caption and the box switched on.

The exact wording lives in `RobotHealth`.

A subscription counts as signed out only when that is proven: it has no saved sign-in, or the
helper answered without it. A helper that couldn't answer proves nothing. `SubscriptionSignIns` is
the one answer the hub and the Brain page share, so they cannot disagree. It asks the bundled helper
only when a sign-in is saved, so opening Settings never starts the helper for nothing, and it takes
the answers Connections gets from its own probes, cancelling any older probe still in flight.

**Refresh.** Visiting the hub and the window becoming key both re-read everything and probe the
sign-ins; coming back from System Settings is the usual way a grant changes. While the window is
open, preference edits re-judge the parts through `UserDefaults.didChangeNotification`, coalesced
into one refresh per burst (a slider drag) and never probing. Only while open, because Foundation
posts that notification for every write in the app, including a write of an unchanged value. The
same fact is why reading the route never writes: `BrainPreferences` rewrites the stored fallback list
only when normalization dropped an entry, so a refresh cannot trigger itself. Saving an API key
writes a file, not a preference, so a saved key refreshes the hub directly.

**Notices.** The four head pages show their part's advice as an amber notice above the page body,
its first sentence in bold. **Open Connections** is the one fix Settings takes the user to; the
permission notices name the System Settings pane instead, because nothing in the live pipeline or
Settings opens another app on its own.

**Live state.** While a session is coaching, the meter reads **ONLINE · COACHING**, the Brain slot
reads **THINKING WITH PRIMARY**, **THINKING WITH FALLBACK n**, or the provider's name when the
active target is not in the saved route, and the robot's eyes brighten while its mouth moves faster.
This follows the same active target as the Brain page's **In use** marker and never changes saved
settings. A Brain problem outranks the live line, because it is what the user can act on.

### Motion

Opening a page from the hub grows it out of the point that opened it (the slot, the head part, or
the dock button) while the hub swells slightly and fades; Back shrinks the page into the same
point. A move from one page to another (a notice's fix button) grows from the center, and Back from
there still returns to the hub's original point. Both use a critically damped spring with a 0.38 s
response, and a move that starts mid-animation begins from what is on screen, so reversing never
jumps. Under Reduce Motion pages cross-fade instead. The origin tells the user where a page came from
and how to get back to it. `SettingsPageTransition` owns the animation and knows nothing about which
pages it moves.

### Sections

| Section class | Page | Description |
|---|---|---|
| `BrainSection` | **Brain**: "Who does my thinking, and how hard I think." | The ordered provider route and the reasoning effort ([Brain](#brain)). Valid route and effort changes take effect between coaching attempts while running, which the header chip says. |
| `TranscriptionSection` | **Ear**: "How I turn the conversation into text." | The transcription provider and its model, language, vocabulary, mode, or locale rows ([Ear](#ear)). Applies on the next Start. |
| `DisplaySection` | **Eye**: "What I look at when I check your screen." | One **Screen capture** card with the capture-scope dropdown — **Active window** (default) or one **Entire display** entry per connected display — and the optional Chrome text switch, followed by a short fallback/privacy callout. Persists via `ScreenCapturePreferences` and applies to the next screenshot ([Capture Scope](#capture-scope)). |
| `OverlaySection` | **Mouth**: "How my hints show up on your screen." | Two matching cards, one per overlay surface — **Overlay Caption** (the transient on-screen tip) and **Overlay Box** (the persistent response history). Each card has an icon, description, On/Off switch, and the same text size and opacity rows; the box also carries the detail box's own rows, with no switch of their own. When a surface is **on** its rows and live sample appear only while the Mouth page is visible (`didBecomeActive`/`didResignActive`); when **off**, its rows and sample are hidden and the card collapses. The header's live chip says the sliders act on screen. Persists via `OverlayAppearance` ([Overlay Appearance](#overlay-appearance)). |
| `ConnectionsSection` | **Connections**: "The accounts and keys I use." | Shared authentication and provider readiness in three stacked cards — **OpenAI API**, **Gemini API**, **Subscriptions** ([Connections](#connections)). The header chip counts what is ready. |
| `ToolsSection` | **Tools**: "Extra things I can reach for while coaching." | Prep notes search, with its switch and its list of local note files and folders ([Tools](#tools)). Applies on the next Start. |
| `SkillsSection` | **Skills**: "Coaching know-how I load when a matching question comes up." | One card per bundled coaching skill, each with its own switch ([Skills](#skills)). Applies on the next Start. |
| `HotkeySection` | **Shortcuts**: "Ask me for help without waiting." | Independent **Give me a hint**, **Explain more**, and **Show code** recorders, with per-binding failure feedback and persisted combinations ([Shortcuts](#shortcuts)). |
| `ActivitySection` | **Activity**: "What I heard and said, session by session." | Embeds the `ActivityViewer` content (`makeContentView()` / `teardown()`) in the shared page/card shell so the adaptive light/dark feed stretches with the window. Its compact toolbar shows the selected session's exact directory ID with **Copy ID**. A session without a report shows **Evaluate**: one click runs the sole `AgenticEvaluator` through a locally installed Claude Code / Codex CLI over the source checkout plus the complete session directory, writes owner-only `eval-report.md`, and opens it. Development uses the live checkout containing the bundle; releases read build identity from the session directory name and use matching or available release source with a disclosed mismatch, as defined in [build-and-run.md](./build-and-run.md#the-live-activity-viewer), including progress states, saved-report reuse, and failure handling. The agent reads the full unfiltered `jarvis-activity.jsonl` whenever it needs the user-visible sequence and correlates it with `coaching-attempts.jsonl`, `brain-traffic.jsonl`, screenshots, and source. The derived transcript leads with a neutral artifact/distribution/correlation-field index and normalized provider-call telemetry; missing evidence remains unavailable, and neither table declares a defect. The findings-driven prompt gives the read-only agent file and source-search tools instead of a historical-incident checklist, and the report uses generic Summary / Findings / Evidence gaps / Recommendations sections. `scripts/eval-session.sh` is a second launcher for this same `JarvisEvaluation` evaluator, not another evaluation path. `EvalReportPage` renders the markdown as `eval-report.html`; **Copy as Markdown** hands the raw report to an agent chat. Evaluation, report opening, and history clearing stay disabled through the live coaching/teardown lifecycle. |

`AppDelegate` builds the hub model, the hub, and the section list at launch and passes them to
`SettingsWindow`. Every page is always reachable, but its content is created lazily on its first
visit during that open.

## Activation-Policy Switch

`SettingsWindow` runs non-modal. Because the app normally runs as `.accessory` (no Dock icon),
`show()` promotes the activation policy to `.regular` so the window can become key and accept
paste/keyboard input. `windowWillClose(_:)` drops it back to `.accessory`. This is the same pattern
the old API-key dialog and activity viewer each learned independently — now consolidated in one
place. The hub and every page render from preferences immediately. The hub, Brain, and Connections
ask the bundled helper for sign-in state away from the main actor and update when that probe
answers, so a helper that is still starting cannot delay presentation.

## Overlay Appearance

Overlay appearance is persisted through `OverlayAppearance`; every key, default, and clamp range is
declared in [`Defaults.Overlay`](../Sources/JarvisCore/Config/Defaults.swift). Each surface carries an
on/off flag, a font size, and an opacity; the box additionally carries its width and height.

The two surfaces default opposite ways — the caption **off**, the box **on** — so a first run shows
the durable history rather than a flashing caption. `AppDelegate` applies both enabled flags at launch.

The box is a **session surface**: switched on, it reaches the screen on Start (already cleared, for the
new conversation) and leaves it on Stop, so a stopped Jarvis puts nothing on the desktop. Two flags in
`OverlayBoxPanel` decide it — the Settings switch (`setEnabled`) and the session (`setSessionLive`,
called by `SessionComposition` from the one line that declares a session live and the one that ends it) — and
a single private `applyVisibility()` derives `isEnabled && isSessionLive`. Keeping that rule in one
place is why the panel, not the two call sites, owns it: switching the box on from Settings while
stopped would otherwise leave it on screen with no session behind it. The Settings preview overrides
the rule while the Mouth page is open and re-derives it on close.

Opacity governs the background fill only, so both surfaces accept 0%: a text-only surface with no
backdrop, not a hidden one. Nothing here takes a surface off screen: that is the On/Off switch, and
for the box the end of a session as well. Both share one range because the page presents their
sliders identically. A corrupted non-finite stored value restores the setting's own default rather
than the range floor, which at 0% would read as breakage.

The Overlay Box card carries **Detail text size** and **Detail background opacity** sliders for the
[detail box](./architecture.md#the-detail-box), under the box's own Text size and Opacity rows. They
persist through `OverlayAppearance` independently of the history controls and apply live. The detail
box defaults to a compact size and an opaque backdrop; the selected size is the preferred size, with
its fit-to-space reduction retained. Separate background regions let its opacity reach zero without
revealing the history fill beneath it. There is no switch of its own: the Overlay Box switch decides
whether a reply may carry a detail at all, and the model judges when one helps. Before the first
reply with a detail arrives, no detail area is reserved.

The box is the one surface the user sizes directly, by dragging its edges. `OverlayBoxPanel` reports a
finished drag through `onSizeChanged` and takes the restored size as an `init` parameter, so the panel
never touches UserDefaults and the size round-trips like every other appearance value. Construction,
not a later `setContentSize`, is what applies it: `setContentSize` pins the frame's top-left, so
resizing after the fact would leave a larger-than-default box off the centre `init` chose, and
re-centring afterwards would mean a second `center()` call. Building the panel at its final size and
centring once keeps placement correct by construction and keeps the AppKit surface minimal — which
matters here, because this panel is built on a CI runner with no GUI session.

The drag hook is `OverlayBoxResizeAffordanceView.onResizeFinished`, fired once when the user lets go
of an edge, not per frame — a per-frame signal would rewrite the preference dozens of times per
gesture. The affordance owns the drag itself (see [architecture.md → Overlay Box](./architecture.md)),
so AppKit is not the one resizing and its `viewDidEndLiveResize` does not fire for these; the box's
content view keeps that hook only for any resize AppKit still drives. Assigning `NSWindow.delegate`
would reach the same event but blocks AppKit without a GUI session, hanging every main-actor test on
CI. A programmatic resize raises no signal on either path, so nothing Jarvis does to the panel can
read back as a user edit — including collapsing it, which reports the height the user last dragged to
rather than the header's. The panel's `minSize` derives from the persisted range floors, so the drag
floor and the clamp floor cannot drift apart, and the affordance clamps its own drags against the
same `minSize`/`maxSize`.

`OverlaySection` applies changes live through two protocols, with no direct dependency on the AppKit
panels: `OverlayCaptionApplying`, conformed by `OverlayCaptionPanel`, and `OverlayBoxApplying`,
conformed by `OverlayBoxPanel`. Both are declared in
[`OverlayAppearance.swift`](../Sources/JarvisCore/Config/OverlayAppearance.swift). All values
round-trip through `OverlayAppearance` so they survive an app relaunch.

`setEnabled(false)` on the caption suppresses coaching tips (dropping any in-flight/queued tip); on
the box it takes the window off screen, and `setEnabled(true)` returns it there only while a session
is running. A surface's live sample is shown only while the Mouth page is visible **and that
surface is on** — `didBecomeActive` previews each surface for its enabled state, and flipping a
switch shows/hides that surface's sample (and collapses/expands its sliders via `relayout()`) live.
Each panel's `showAppearancePreview(_:)` re-asserts capture exclusion so the preview stays hidden
from screen capture — same defense-in-depth as the coaching display path. The box's preview shows
sample text without disturbing the real log and re-derives `isEnabled && isSessionLive` on close, so
leaving the page can leave the box on screen only while both hold. The box's sample stands in **only
while stopped**: during a session the box is already on screen carrying the conversation's own tips
and the sliders apply to it live, so a sample would replace real content with something worse. That
boundary is a correctness one as much as a display one, because it is what guarantees no tip can land
behind a sample and no collapse snapshot can cross a session boundary. Start therefore takes the
sample down.

Settings cannot see the session, so `showAppearancePreview(_:)` records a request rather than
obeying one, the way `setEnabled(_:)` does: the sample shows when Settings wants it **and** no session
is running, derived in one place. A request made during a session is still standing when the session
stops, so a Stop taken without leaving the page brings the sample up rather than leaving the sliders
with nothing on screen to act on. Which source is showing is a value, `Display.log` or `.sample`, and
the readout and the clear button are derived from it together rather than each asking whether a
preview is running. The plain setters
(`setFontSize`/`setBackgroundOpacity`/`setOpacity`) only change appearance and don't touch
`sharingType`. See [overlay-invisibility.md](./overlay-invisibility.md).

## Shortcuts

**Give me a hint** defaults to **⌥⌘J**, **Explain more** to **⌥⌘E**, and **Show code** to **⌥⌘K**.
They work during a session. All three are fallbacks for proactive coaching;
[architecture.md](./architecture.md#on-demand-coaching-shortcuts) defines their context, output, and
scheduling behavior. Each card uses `HotkeyBindingView` and the
existing recorder, requiring Command or Option. A successful rebind takes effect immediately and
persists only that shortcut through `HotkeyPreferences`; defaults and storage keys live in
`Defaults.Hotkey`. Escape cancels recording.

**Explain more** and **Show code** both answer into the detail box, so the Overlay Box switch is the
only thing that decides whether they can be bound: with the box off, their recorders are disabled and
their rows say the Overlay Box is needed and that it is switched on in Mouth. Neither has a switch of
its own, and the **Give me a hint** shortcut is unconditional. Whether a session can use them is
fixed at Start: a session that started with the box off never registers them, even if the box is
switched on mid-session, while a session that started with it on releases them when the box is
switched off and registers them again when it is switched back on.

A collision with another application or another Jarvis shortcut leaves the old working binding
active and shows a warning callout under that card. If no binding could be registered at launch, its
warning persists across page visits. The three cards scroll at small window sizes, including when
registration warnings are visible. Resizing or changing a binding card preserves the reading offset,
clamped to the available content. The Overlay Box shows semibold hints in its upper section and the
reply's detail in the lower one; a hint whose reply carried a detail ends with a dim marker. Both use
the configured text size, and the appearance preview shows an example. Neither surface's visibility
preference changes. No shortcut enables the master box.

## Activity response sections

Each coaching response retains its delivered **Hint** and optional **Detail** as separate fields
through `ActivityResponse`. The Activity feed labels each present part, and the detail is written out
as the Markdown the model sent, fences and indentation intact. The same sections survive live replay,
reopening a saved session, and Markdown, plain-text, or HTML export. The recorder includes only the
detail the overlay actually accepted.

A session whose responses carry **Explanation** and **Code** fields opens and exports with those
sections: `ActivityResponse` decodes both fields and never writes them. Older sessions with no structured response fields at all display their original
messages; Activity does not guess boundaries from flattened prose. Every record also retains a
readable text message for older readers and the session evaluator; structured fields drive the
sectioned viewer.

## Brain

The Brain page owns the whole "who answers a coaching attempt" decision, persisted through
`BrainPreferences` (UserDefaults).

The page header sits above one vertically scrolling stack of two rounded groups: **Provider route**
and **Reasoning effort**. The Provider group is one uninterrupted route: Primary and every Fallback
row share the same label / provider / model alignment. There are no row dividers or permanent
explanatory paragraphs. Fallback rows expand the outer document instead of hiding inside a second
scroll area. While coaching runs, a compact teal **In use** tag exposes the runtime cursor without
moving or rewriting any saved target.

**Primary.** The first row selects a provider and model: the **OpenAI API** (metered by the key), the
**Codex** (the user's ChatGPT plan), or **Claude Code** (the user's Claude
plan). Both subscriptions are served by the helper bundled in the app and signed in from
[Connections](#connections); see
[architecture.md → Subscription targets through the bundled proxy](./architecture.md#subscription-targets-through-the-bundled-proxy).
A subscription can be chosen for a new row only while the helper's last answer proved it signed in,
so the menu omits a signed-out one; an existing saved row stays visible so the user can repair or
remove it. The Brain page reads that answer from `SubscriptionSignIns` ([Status](#status)), which
probes when the page appears and only starts the helper to do so when a sign-in is saved; with
none, no subscription is selectable and nothing starts. The route menus show provider names only;
Connections owns sign-in status text.

A fresh install opens on the **OpenAI API** as Primary, so the Brain page always shows a complete,
usable route and Start never fails for want of a provider choice. That default costs the user nothing
extra: transcription defaults to OpenAI too, so the same one credential covers both, and a user who
wants a subscription brain signs in from Connections and changes Primary in one visit. There is no
"unconfigured" state; the saved route is always complete.

**Fallbacks and order.** Below the primary, an ordered list contains zero or more explicitly
authorized provider/model targets. **Add fallback** appends a row. Every row, the primary included,
has accessible `↑` / `↓` actions that swap it with its neighbor (`BrainRoute.movingTarget`), so the
primary can move down and a fallback can become the primary. Only fallback rows have `×` (Remove),
because a route always has a primary; the primary keeps the empty slot so its arrows line up with
the rows below. Rows are labelled **Primary**, **Fallback 1**, **Fallback 2**, and so on by position,
so visual order and failover order are identical. Exact duplicate targets are rejected; a second
model from the same provider is allowed as a deliberate separate target. Edits save immediately and
apply on the next coaching attempt, which the header chip says.

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

A signed-out subscription is hidden from new selection while editing; an existing saved row stays
visible so the user can repair or remove it. A configured target that cannot serve when the session
starts or the route is edited (a signed-out subscription, or a helper that isn't running) stays in
the runtime route as an unavailable entry: activation skips it with a notice and moves forward
without inventing provider requests solely to consume the failure budget. Start is refused, with an
alert naming the first target's next step, only when no target in the route can serve, because a
route with one usable target can still coach. Runtime movement through the route never changes the
saved list. Stop → Start begins at the saved primary again.

**Model + reasoning effort.** A **Model** dropdown is drawn from `BrainModelCatalog` per provider.
The OpenAI API and Codex share one concrete model list; Claude Code
exposes the current concrete Claude releases, including the latest in each supported family and
older choices needed to preserve saved routes. A listed model Codex does not serve
fails at request time with the helper's `model_not_found`, which reads as a configuration failure.
Adding a model keeps provider defaults and existing selections stable. Concrete releases, never
rolling aliases such as `sonnet` or `opus`: a saved route must keep naming the release the user
picked, and an alias silently retargets it the day the provider advances it. Claude Haiku 4.5 is
listed by its dated id because the helper does not resolve the undated one. Each provider remembers
its own model; without a valid preference, the first entry in that provider's catalog is selected.
Moving a route row moves that provider's remembered model with it when the row becomes the primary.
The **Reasoning effort** group (`ReasoningEffort`: None / Low / Medium / High) is a four-segment
control whose segments show short labels and the prototype's bar glyphs, with the full name as each
segment's tooltip, so all four fit at the window's minimum width. The effort is stored once and
applies uniformly to whichever provider is active; its default lives with the others in
[`Defaults.Brain`](../Sources/JarvisCore/Config/Defaults.swift). `BrainAccessor` raises None to Low,
and the output budget to at least the Low budget, for Claude Code, because None disables
thinking on that path and Claude Fable 5.1 rejects it, and for GPT-6 Astra, because Astra requires
reasoning. The stored effort remains unchanged, and every other target keeps the selected effort.

Reads are validated: a persisted primary model id no longer in that provider's catalog uses the
provider default without rewriting the invalid value, while invalid fallback rows are removed during
route normalization, and the stored list is rewritten only when that removed something. An
unrecognized provider/effort likewise uses its existing default rather than reaching the API. A
running `CoachDriver` applies valid brain edits atomically at the coaching-attempt boundary while
transcript, client-managed history, audio pipeline, and session logs continue unchanged. A provider,
model, or route-order edit, moving the primary included, replaces the route for the next attempt
and resets the session-local cursor to the newly selected primary. This topology edit is the only way
to revisit a target that automatic failover left behind. The old active provider is not retained as
a hidden fallback; it remains available only when the user includes it in the new list.

A reasoning-effort edit instead rebuilds the clients at the current forward-only cursor and preserves
its failure counts. An attempt already in flight keeps its snapshotted client and remains
authoritative: its success or failure updates route health normally, and the new effort begins with
the next attempt.

An edit to a route that names a subscription reads the helper first, so it meets the sign-ins
Settings showed. A route edit in which no target can serve is refused: the running route stays
intact, Activity records fixed settings-not-applied copy, and the same alert as a refused Start
names the next step. An edit whose route names the OpenAI API while no key is saved is refused the
same way, without the alert. Provider-specific partial tool-loop state from a failed attempt is
discarded, while provider-neutral pending conversation follows the newly installed route on its next
attempt. While stopped, persisted changes apply on the **next Start**. The helper's later state is
not a routing signal: if it stops or a subscription is signed out mid-session, that target's attempt
fails and follows the normal fresh-attempt route policy.

Brain-route choices persist via `BrainPreferences`. That type owns validation and normalization;
every key and default value it reads comes from
[`Defaults`](../Sources/JarvisCore/Config/Defaults.swift), and the per-provider model lists from
`Sources/JarvisCore/Brain/BrainModelCatalog.swift`.

## Tools

The Tools page lists the coaching tools the user can switch. Prep notes search is the only one: the
always-on tools (screen capture, speak, stay silent) aren't listed, because Jarvis cannot start
without screen capture and a turn cannot end without one of the other two. Its one card holds the
**Search my prep notes** switch and, below it, the list of local note files and folders the search
reads, with **Add files or folders…** and a remove button per source. The switch is always enabled.
When it is on with no sources, its detail asks the user to add notes, because the runtime offers
`search_prep_notes` only when sources exist
([architecture.md → Capabilities](./architecture.md#capabilities)). Switching it off hides the list
and keeps it; switching it back on shows the same list.

Jarvis stores only the chosen paths (`PrepMaterialPreferences`), never a copy of their contents, and
reads them fresh when needed, so removing a source only forgets it; a callout under the card says
so. The file picker accepts the formats prep indexing can read. Whether each source still exists is
checked off the main thread, because a stat can block on a network volume or a sleeping disk; a
missing source shows its title and path in amber. The page re-checks every time it becomes visible.

## Skills

The Skills page shows one card per bundled coaching skill (`SkillCatalog.bundled()`; there are four),
titled from the skill's folder name (`Skill.displayTitle`) and described by its `SKILL.md`
`description` verbatim, so the text the model reads and the text the user reads have one source.
Every card uses the same sparkles icon. Each card has its own switch and reads **EQUIPPED** or
**UNEQUIPPED**; a switched-off card dims but keeps a live switch, so it can be switched back on. The
cards sit in two columns, or one on a narrow window. The catalog is read when the page is built.

Tools and Skills write `BrainPreferences.disabledTools` and `BrainPreferences.disabledSkills`, the
names that are OFF, so a capability added in a later version is on for everyone who never opened
these pages, and nothing else: a session resolves its capabilities once at Start and builds its
instructions and tool set from that one value, so a mid-session change would contradict what the
model was told earlier in the same conversation. Both header chips say edits apply on the next
Start. See [architecture.md → Capabilities](./architecture.md#capabilities).

## Ear

The Ear page (`TranscriptionSection`) owns the speech-to-text role without conflating it with the
brain route. Its one card is `TranscriptionControls`, whose header detail says which key it uses or
that it runs on this Mac. The provider picker contains **OpenAI** (the default), **Gemini**, and
**Apple Speech (macOS 26+)**. Apple is enabled only when the running Mac and OS expose
`SpeechTranscriber`; selecting any provider persists through `TranscriptionPreferences` and applies
on the next Start, never halfway through a live session. `TranscriptionControls` shows one fixed row
set per provider — the provider row plus only that provider's rows (`visibleRows`) — so switching
providers never leaves a stale control from the previous choice visible.

With OpenAI selected, **Model** offers **GPT-4o Transcribe** (the default), opt-in **GPT
Transcribe**, and opt-in **GPT Live Transcribe** for session-by-session comparison. **Expected
languages** is a multi-select generated from the supported language values; English and Mandarin
are currently available and can be selected independently. No selection means Automatic and
sends no language hint. One selection guides recognition but does not translate. Multiple selections
are sent to GPT Transcribe and GPT Live; GPT-4o remains automatic because it accepts at most one
language hint, and the row says so whenever GPT-4o has multiple selections. The canonical list is one
immutable Start-time expectation shared by `me` and `them`,
so the transcription model—not a Jarvis per-turn classifier—handles a speaker switching languages
inside one sentence. **Vocabulary** is a free-text, comma-separated glossary of literal terms
(jargon, names) sent as `keywords` to bias recognition; it applies only to GPT Transcribe and GPT
Live and the row says so whenever GPT-4o Transcribe is selected. Blank entries are dropped on save.
Model-specific language, context, and turn-detection behavior is defined in
[architecture.md](./architecture.md#models-and-apis).

With Gemini selected, the card shows its own **Model**, **Expected languages**, **Vocabulary**, and
**Mode** rows, backed by their own preference fields (`geminiModel`, `geminiExpectedLanguages`,
`geminiVocabularyKeywords`, `geminiMode`) — none shared with the OpenAI rows above. **Model** offers
the one live/streaming model Jarvis supports (`GeminiTranscriptionModel`; Gemini's batch model has no
place in a live coaching session). **Expected languages** and **Vocabulary** behave the same as their
OpenAI counterparts — a multi-select language hint (empty means automatic) and a comma-separated
glossary sent as `customVocabulary` — but always apply, since Gemini's one live model accepts both
without the GPT-4o carve-out. **Mode** (`GeminiTranscriptionMode`) picks **Verbatim** (the default,
preserves the raw utterance) or **Smart** (removes filler words and formats the output, so it reads
better but is no longer exactly what was said). Gemini's turn detection, wire format, and the
provider-derived wire sample rate are covered in
[architecture.md](./architecture.md#models-and-apis).

With Apple Speech selected, **Conversation locale** is populated from
`SpeechTranscriber.supportedLocales`; the initial suggestion is the supported equivalent of the
current macOS locale. Start downloads or reuses that selected model before replacing a running
pipeline. Apple Speech uses one locale for the whole session, which the row says. Jarvis does not run
parallel Apple transcribers, and the runtime never falls back to OpenAI implicitly if the Apple
analyzer fails.

Transcription preferences are validated independently: unknown OpenAI model ids use GPT-4o; unknown
or duplicate expected-language values are discarded and the remaining values use stable declaration
order; an empty list means Automatic. Gemini's model, expected languages, vocabulary, and mode each
fall back to their own default the same way on an unrecognized stored value. Existing fixed-profile
preferences are read into the matching list until the user edits it. An unsupported Apple locale
fails visibly at Start rather than choosing a different language. The provider, OpenAI
model/expected-language list, and Apple locale persist via `TranscriptionPreferences`, whose keys and
defaults come from [`Defaults`](../Sources/JarvisCore/Config/Defaults.swift).

## Connections

The Connections page owns authentication shared across Brain and Ear. Its three stacked
cards are **OpenAI API**, **Gemini API**, and **Subscriptions**. The OpenAI and Gemini
cards each report and edit only their own Jarvis-managed owner-only file through `APIKeyControls`
(one instance per `Credential`, keyed by `credential.rawValue` so their accessibility labels,
identifiers, and saved-key state never collide); each card's header says what the key is used for,
and its action is **Add API key** or **Edit**, beside a teal **Saved** badge once a key is saved.
The `OPENAI_API_KEY` fallback remains usable by Start but is deliberately not presented as a
Jarvis-managed saved key; Gemini has the same headless fallback in `GEMINI_API_KEY`
(`Credential.geminiAPIKey.environmentVariable`, read by `EnvSecretStore`), also not presented as a
saved key.

Saving a key checks it. One models-list request goes out with the key in a header, and the card shows
what the vendor said under the row: **accepted**, **refused** with the provider's status, error code,
and redacted message, or **couldn't check the key** carrying the same evidence. The check answers one
question, whether the provider refused the key, so only an authentication failure is a refusal. An
exhausted quota, a blocked region, a rate limit, and a 5xx are all real problems, but none of them is
the key being wrong and rotating it fixes none of them, so each lands in the third case with its
cause quoted. They are not worth telling apart here: a session that actually hits one of them names
it in Activity. The verdict comes from the same
`CredentialCheck` table a live session uses (see
[architecture.md → One failure record](./architecture.md#one-failure-record-one-table-per-vendor)),
so Settings and a session that dies on the same key cannot disagree. The check never gates the save:
the key is written first, and a check that fails or times out lands in the inconclusive case with its
cause rather than blocking anything. While the request is in flight the card reads **Checking the key
with …**; closing the window cancels the check and clears that state, so the next open shows no
answer rather than a check that is no longer running. An answered verdict belongs to the key that was
checked, so it survives a reopen and is cleared by editing the key. The request is a models list
rather than a real completion because it
costs nothing and still proves the key, the network path, and the region; it does not prove billing,
which OpenAI only reports on a real request, which is why the wording is "accepted" rather than a
claim that the account is healthy.

The **Subscriptions** card (`SubscriptionControls`) has one row each for **Codex**
and **Claude Code**. Opening Connections probes the bundled helper, starting it if it is
not running, and reads its credential files, so each row says what a Start would find; each answer
also updates `SubscriptionSignIns`, so the hub and the Brain page agree with this card:

- **Checking…** until the probe answers.
- **Signed in** (teal), with the account's email and plan, and a **Sign out** button.
- **Signed out**, with a **Sign in** button.
- **Not usable** (amber) when a sign-in is saved but the helper does not serve that vendor, which
  usually means the sign-in expired; **Sign in** replaces it.
- **Not running** (amber), with the helper's own reason and a **Try again** button that probes again.
- **Signing in…** while a sign-in runs, with a **Cancel** button.

**Sign in** runs the helper's login for that vendor, opens the vendor's sign-in page in the default
browser, and waits up to ten minutes for the browser to hand the account back. It is the one place
Jarvis opens a URL, and only because the user pressed the button. A failed sign-in shows the helper's
redacted reason under the row. **Sign out** deletes that vendor's credential files. Jarvis never
reads the tokens itself: they stay in the helper's owner-only credential directory, apart from the
secrets file ([sandbox.md](./sandbox.md) says where, and what a login reaches). The page's header
chip counts every managed API key that is saved and every subscription the last probe proved signed
in.

An OpenAI key is required only when OpenAI is selected for transcription or appears anywhere in the
brain route; a Gemini key is required only when Gemini is selected for transcription — Gemini is not
a brain provider. Apple Speech plus a subscription-only route can start without either key. Saving a
managed key while a session runs preserves route health: an OpenAI save refreshes both the OpenAI
brain clients and a live OpenAI transcription socket's future reconnect credential, while a Gemini
save refreshes only a live Gemini transcription socket's future reconnect credential. Neither ever
replaces a subscription client, and a saved credential only ever reaches the transcriber built for
that same provider.

## Capture Scope

What `capture_screen` shoots, chosen on the Eye page — one dropdown covering both the scope and, for
entire-display capture, the display: **Active window (recommended)** plus one **Entire display**
entry per connected display. Active-window mode reads the window server's single front-to-back z-order at capture time
(`WindowScopedScreenCapture` in `JarvisApp/Capture`, with the pick itself pure logic in Core's
`FrontWindowSelector`) and shoots the window the user last clicked or typed into — whichever
display it lives on — via `screencapture -l`, which reads the window's own backing image (clean
even when partially covered; `-o` omits the shadow). Jarvis's own windows, non-app layers (dock,
panels), and tiny layer-0 helper windows are skipped.

The window shot also gets typed text evidence. **Read Chrome page text** is off by default. When the
user turns it on while Jarvis is stopped and grants the optional macOS Accessibility permission,
`BrowserAccessibilityReader` performs read-only queries against the exact foreground Chrome window
chosen for the screenshot. It extracts bounded text from that window's active web area, excludes
secure fields, and may include content above or below the viewport. It does not read raw HTML,
background tabs, browsing history, cookies, or hidden form values, and it never scrolls or changes
the page. Jarvis checks the active document identity around JPEG capture and discards Accessibility
text if the tab changes, leaving OCR as the matching evidence. Accessibility trees remain incomplete
for lazy or virtualized content, editors such as
Monaco, canvas, images, and diagrams. The switch remains Off unless permission is live. Enabling may
request permission only while stopped; turning it Off is available during a session and applies to
the next coaching attempt.

`ScreenTextRecognizer` always runs Apple Vision OCR (`.accurate`, language correction off) on an
active-window screenshot. OCR is marked as current-viewport, fallible evidence and accompanies
Accessibility text when that source is available. The screenshot stays ground truth for diagrams,
layout, and visible exact-token claims. Screen evidence has no separate historical cache.
Nothing eligible on screen falls back to a full shot of the **main display**; fallback and
entire-display captures omit text evidence because a whole display would include unrelated clutter.

The **Entire display** entries are named and numbered the way `screencapture -D` counts displays
(1 = the main display, the one with the menu bar; the dropdown enumerates `NSScreen.screens`, main
first, matching that order) and refresh when displays are plugged or unplugged while the Eye page is
visible. The chosen display persists as the 1-based `-D` index alongside the scope.

The scope, display, and browser-text choice are frozen in the session plan used by an attempt. A
change applies at the next attempt boundary. Reads are validated: an unrecognized
stored scope falls back to the default, a stored index < 1 clamps to the main display, and if the
chosen display no longer exists (the monitor was unplugged since it was chosen) `screencapture -D`
fails and `ScreenCaptureCLI` reshoots the main display rather than dropping the screenshot.
Fallbacks from active-window scope always capture the main display — a display index left over
from an old entire-display selection never steers them. A transient-file cleanup failure is not an
ordinary capture failure: it poisons the session-local runner and returns without a window/display
fallback or a later capture.

Both values, their keys, and the main-display floor are declared in
[`Defaults.Screen`](../Sources/JarvisCore/Config/Defaults.swift).

## Key Files

| File | Role |
|---|---|
| `Sources/JarvisApp/Settings/SettingsSection.swift` | Page protocol definition |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | Host window: hub and page container, navigation, notices, settings observation |
| `Sources/JarvisApp/Settings/SettingsDestination.swift` | Every page's identity and the head-part-to-page map |
| `Sources/JarvisApp/Settings/SettingsPageTransition.swift` | The grow-from-origin page animation and its Reduce Motion cross-fade |
| `Sources/JarvisApp/Settings/SettingsTheme.swift` | Every Settings color, per appearance and contrast |
| `Sources/JarvisApp/Settings/NSView+SettingsTheme.swift` | Resolves a theme color for a layer property |
| `Sources/JarvisApp/Settings/SettingsBackgroundView.swift` | The radial window backdrop |
| `Sources/JarvisApp/Settings/SettingsStyle.swift` | Shared page/card/row sizing and spacing tokens |
| `Sources/JarvisApp/Settings/SettingsPageView.swift` | Page header (back, badge, title, summary, chip), notice, and content shell |
| `Sources/JarvisApp/Settings/SettingsBackButton.swift` | `‹ JARVIS`, bound to ⌘[ |
| `Sources/JarvisApp/Settings/SettingsNoticeView.swift` | A page's amber notice and its fix button |
| `Sources/JarvisApp/Settings/SettingsCardView.swift` | Rounded group boundary, optional header, and resize callback |
| `Sources/JarvisApp/Settings/SettingsCardStack.swift` | Shared top-aligned scrolling column of cards |
| `Sources/JarvisApp/Settings/SettingsCalloutView.swift` | Shared info and warning callout |
| `Sources/JarvisApp/Settings/SettingsRowView.swift` | Shared label/help/trailing-control row |
| `Sources/JarvisApp/Settings/SettingsScrollView.swift` | Viewport-change adapter for variable-height documents |
| `Sources/JarvisApp/Settings/Home/SettingsHome.swift` | The hub page's lifecycle |
| `Sources/JarvisApp/Settings/Home/SettingsHubModel.swift` | Reads the hub's inputs and publishes `RobotHubState` |
| `Sources/JarvisApp/Settings/Home/SettingsHomeView.swift` | Hub layout: header, meter, robot, slots, connectors, dock |
| `Sources/JarvisApp/Settings/Home/RobotHeadView.swift` | Jarvis's head, drawn and animated in code; `+Geometry` holds its shapes |
| `Sources/JarvisApp/Settings/Home/RobotSlotView.swift` | One part's slot button |
| `Sources/JarvisApp/Settings/Home/HomeDockButton.swift` | One chamfered dock button |
| `Sources/JarvisApp/Settings/Home/ReadinessMeterView.swift` | The hub header's readiness meter |
| `Sources/JarvisApp/Settings/Home/RobotPart+Presentation.swift` | Each part's title and symbol |
| `Sources/JarvisApp/Settings/SubscriptionSignIns.swift` | The one sign-in answer shared by the hub and the Brain page |
| `Sources/JarvisCore/Config/RobotHub.swift` | Inputs → hub state, the hub's one decision point |
| `Sources/JarvisCore/Config/RobotHealth.swift` | The hub's status rules |
| `Sources/JarvisCore/Config/RobotPartSummaries.swift` | Each slot's saved-setting text |
| `Sources/JarvisCore/Config/RobotHubInputs.swift`, `RobotReadiness.swift` | Everything the hub reads |
| `Sources/JarvisCore/Config/RobotHubState.swift`, `RobotSlotState.swift`, `RobotHubMeter.swift`, `RobotPartHealth.swift`, `RobotPartSummary.swift`, `RobotPart.swift` | What the hub shows |
| `Sources/JarvisApp/Settings/BrainSection.swift` | Brain page: provider route + reasoning effort |
| `Sources/JarvisApp/Settings/TranscriptionSection.swift` | Ear page |
| `Sources/JarvisApp/Settings/ToolsSection.swift` | Tools page: prep notes search and its sources |
| `Sources/JarvisApp/Settings/SkillsSection.swift` | Skills page |
| `Sources/JarvisApp/Settings/SkillCardView.swift` | One skill's card |
| `Sources/JarvisApp/Settings/SkillCardGridView.swift` | Responsive skill card grid |
| `Sources/JarvisCore/Config/Skill+DisplayTitle.swift` | A skill's card title from its folder name |
| `Sources/JarvisApp/Settings/ConnectionsSection.swift` | Per-credential API-key editors (OpenAI, Gemini) + the Subscriptions card |
| `Sources/JarvisApp/Settings/SubscriptionControls.swift` | Subscriptions card: per-subscription status, Sign in, Sign out, and Cancel |
| `Sources/JarvisBrainProviders/Proxy/LocalProxySupervisor.swift` | Starts, probes, and restarts the bundled helper; owns its credential directory |
| `Sources/JarvisBrainProviders/Proxy/LocalProxySignIn.swift` | Runs one browser sign-in through the helper and reports its URL and outcome |
| `Sources/JarvisApp/Settings/CredentialVerifier.swift` | The one models-list request behind a saved key's verdict |
| `Sources/JarvisApp/Settings/BrainTargetRowView.swift` | Shared inline provider/model row for primary and fallback targets |
| `Sources/JarvisApp/Settings/ProviderRouteEditor.swift` | Unified route card and its persistence mutations, including reorder |
| `Sources/JarvisCore/Brain/BrainRoute.swift` | The ordered route, its normalization, and `movingTarget(at:by:)` |
| `Sources/JarvisApp/Settings/TranscriptionControls.swift` | Transcription provider/model/language-or-locale behavior card |
| `Sources/JarvisApp/Settings/ExpectedLanguagePicker.swift` | Scalable expected-language chips + multi-select popover |
| `Sources/JarvisApp/Settings/APIKeyControls.swift` | Collapsed Jarvis-managed API-key editor, one instance per `Credential` |
| `Sources/JarvisCore/Transcription/TranscriptionProvider.swift` | Provider identities, labels, per-provider credential + audio format |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Mouth page: overlay appearance |
| `Sources/JarvisApp/Settings/DisplaySection.swift` | Eye page: capture scope and optional Chrome text controls |
| `Sources/JarvisApp/Capture/BrowserAccessibilityPermission.swift` | User-initiated Accessibility grant and status |
| `Sources/JarvisScreenCapture/BrowserAccessibilityReader.swift` | Bounded, read-only active-tab semantic extraction |
| `Sources/JarvisScreenCapture/ScreenTextResolver.swift` | Combines optional Accessibility text with current-view OCR |
| `Sources/JarvisApp/Settings/OverlaySurfaceSettingsView.swift` | One reusable overlay-surface card and its slider/readout rows |
| `Sources/JarvisApp/Settings/NSScreen+DisplayTitles.swift` | Display naming for the dropdown's entire-display entries |
| `Sources/JarvisApp/Settings/HotkeySection.swift`, `HotkeyBindingView.swift` | Shortcuts page and one binding card |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Activity page |
| `Sources/JarvisCore/Brain/BrainProvider.swift` | The three providers: the OpenAI API and the two subscriptions |
| `Sources/JarvisBrainProviders/LocalAgent/AgentCLIDetector.swift` | The evaluator's CLI binary discovery + bounded authentication-status detection |
| `Sources/JarvisCore/Brain/BrainModelCatalog.swift` | Curated per-provider model lists (`BrainModel`) |
| `Sources/JarvisCore/Brain/ReasoningEffort.swift` | The four effort levels |
| `Sources/JarvisEvaluation/AgenticEvaluator.swift` | Read-only Claude Code / Codex session audit invoked by Activity and `EvalPrep` |
| `Sources/JarvisCore/Config/Defaults.swift` | Every user setting's key, default, and valid range |
| `Sources/JarvisCore/Config/BrainPreferences.swift` | UserDefaults persistence + route validation |
| `Sources/JarvisCore/Config/PrepMaterialPreferences.swift` | The prep note sources Tools lists |
| `Sources/JarvisCore/Coach/CoachDriver.swift` | Between-attempt route application and attempt orchestration |
| `Sources/JarvisCore/Config/ScreenCapturePreferences.swift` | Capture scope + display persistence + clamping |
| `Sources/JarvisScreenCapture/ScreenCaptureCLI.swift` | Executes the attempt's frozen `SessionPlan` capture selection and handles main-display fallback |
| `Sources/JarvisCore/Config/OverlayAppearance.swift` | UserDefaults persistence; `OverlayCaptionApplying` + `OverlayBoxApplying` protocols |
| `Sources/JarvisCore/Config/TranscriptionPreferences.swift` | Persisted transcription selection + validation |
| `Sources/JarvisCore/Overlay/BroadcastOverlay.swift` | Fans one `render` out to the caption + box |
| `Sources/JarvisOverlay/OverlayCaptionPanel.swift` | The Overlay Caption; `OverlayCaptionApplying` conformance |
| `Sources/JarvisOverlay/OverlayBoxPanel.swift` | The Overlay Box; `OverlayBoxApplying` conformance |
| `Sources/JarvisOverlay/NSPanel+CaptureExclusion.swift` | Shared `sharingType = .none` helper for both panels |

## Related Pages

- [overlay-invisibility.md](./overlay-invisibility.md) — capture exclusion re-assert during preview
- [build-and-run.md](./build-and-run.md) — the embedded activity log
