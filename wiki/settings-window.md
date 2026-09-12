# Settings Window — Design

> The unified Settings window consolidates all user-facing configuration into one non-modal panel
> reached via a single menu item. It replaces the old separate API-key dialog and the standalone
> activity-log window that were managed by `MenuBarController`.

## Entry Point

One menu item — **"Settings"** — calls `SettingsWindow.show()`. The lightweight window and tab shell
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
    var fillsTab: Bool { get }        // default: false — built-in sections opt into the full page
}
```

The protocol is the only seam between `SettingsWindow` and the individual panels — sections have no
knowledge of the tab view or each other. `SettingsWindow` is the `NSTabViewDelegate`; on each tab
change it pairs `didResignActive()` on the outgoing section with `didBecomeActive()` on the incoming
one (and resigns the active section on window close). This lets a panel run side effects **only while
its tab is visible** rather than for the whole time the window is open.

### Window sizing

One user-resizable window size for every tab — 820×600 by default, minimum 560×460. Switching tabs
never resizes the window; whatever size the user set stays. Every built-in section returns
`fillsTab == true` and uses `SettingsPageView`, so page margins and headers expand consistently while
cards and trailing controls adapt to the available width. Brain, Connections, Overlay, and Shortcuts put their
variable-height cards in `SettingsScrollView`; Screen and Activity use the same page shell without an
unnecessary outer scroll view.

### Shared visual system

The tabs share four AppKit primitives rather than styling their controls independently:

- `SettingsPageView` owns the page title, one-line summary, optional live status badge, and outer
  margins.
- `SettingsCardView` owns the rounded group boundary and optional title/detail header.
- `SettingsRowView` owns label/help typography, row height, separators, and responsive trailing
  control alignment.
- `SettingsStyle` owns the spacing, corner radius, and sizing tokens used throughout Settings.

Sections still own their behavior and concrete controls. The visual primitives do not read or write
preferences, start probes, load Activity, or know about another tab. Activity keeps its `WKWebView`
lazy lifecycle; its adaptive light/dark feed is simply framed by the same page and card chrome.

### Sections

| Section class | Tab title | Always present | Description |
|---|---|---|---|
| `BrainSection` | "Brain" | yes | Behavior that decides who answers and what Jarvis hears, in one scrolling stack: the primary provider/model, an ordered editable fallback list, reasoning effort, interview format, and transcription provider/model/expected-languages-or-locale controls. A live status badge mirrors the active brain provider without moving the saved route. Valid Brain-route changes take effect between coaching attempts while running; interview format and transcription changes take effect on the next Start. |
| `ConnectionsSection` | "Connections" | yes | Shared authentication and provider readiness in four stacked cards — **OpenAI API**, **Gemini API**, **Claude Code**, **Codex CLI**. OpenAI and Gemini each expose their own Jarvis-managed API-key editor (`APIKeyControls`, one instance per `Credential`); Claude Code and Codex CLI report their externally managed local-account state without importing or changing those accounts. Saving a key never restarts a live conversation: an established OpenAI Realtime or Gemini Live socket stays connected and picks up the new key only on its next reconnect. |
| `OverlaySection` | "Overlay" | yes | Two matching cards, one per overlay surface — **Overlay Caption** (the transient on-screen tip) and **Overlay Box** (the persistent response history). Each card has an icon, description, On/Off toggle, and the same Text Size + Opacity row layout; the box also has **Show diagrams**, enabled by default. When a surface is **on** its rows and live sample appear only while the Overlay tab is selected (`didBecomeActive`/`didResignActive`); when **off**, its rows and sample are hidden and the card collapses. Persists via `OverlayAppearance`. |
| `DisplaySection` | "Screen" | yes | One **Screen capture** card with the capture-scope dropdown — **Active window** (default) or one **Entire display** entry per connected display — followed by a concise fallback/privacy callout. Persists via `ScreenCapturePreferences` and applies to the next screenshot. |
| `HotkeySection` | "Shortcuts" | yes | Independent **Give me a hint**, **Explain more**, and **Show code** recorders, with per-binding failure feedback and persisted combinations. |
| `ActivitySection` | "Activity" | yes | Embeds the `ActivityViewer` content (`makeContentView()` / `teardown()`) in the shared page/card shell so the adaptive light/dark feed stretches with the window. Its compact toolbar shows the selected session's exact directory ID with **Copy ID**. A session without a report shows **Evaluate**: one click runs the sole `AgenticEvaluator` through a locally installed Claude Code / Codex CLI over the source checkout plus the complete session directory, writes owner-only `eval-report.md`, and opens it. While it runs the button shows **Evaluating…**; afterward it becomes **Open report**, which reopens the saved result without another model run. The agent reads the full unfiltered `jarvis-activity.jsonl` whenever it needs the user-visible sequence and correlates it with `coaching-attempts.jsonl`, `brain-traffic.jsonl`, screenshots, and live source. The derived transcript leads with a neutral artifact/distribution/correlation-field index and normalized provider-call telemetry; missing evidence remains unavailable, and neither table declares a defect. The findings-driven prompt gives the read-only agent file and source-search tools instead of a historical-incident checklist, and the report uses generic Summary / Findings / Evidence gaps / Recommendations sections. `scripts/eval-session.sh` is a second launcher for this same `JarvisEvaluation` evaluator, not another evaluation path. `EvalReportPage` renders the markdown as `eval-report.html`; **Copy as Markdown** hands the raw report to an agent chat. Evaluation, report opening, and history clearing stay disabled through the live coaching/teardown lifecycle. |

`AppDelegate` builds the section list at launch and passes it to `SettingsWindow`. All tabs are
always present, but each tab's content is created lazily on first selection during that open.

## Activation-Policy Switch

`SettingsWindow` runs non-modal. Because the app normally runs as `.accessory` (no Dock icon),
`show()` promotes the activation policy to `.regular` so the window can become key and accept
paste/keyboard input. `windowWillClose(_:)` drops it back to `.accessory`. This is the same pattern
the old API-key dialog and activity viewer each learned independently — now consolidated in one
place. Initial Brain controls render from preferences immediately. Brain and Connections run CLI
status and capability subprocesses away from the main actor and update their controls when those
probes finish, so bounded timeouts cannot delay presentation.

## Overlay Appearance

Overlay appearance is persisted through `OverlayAppearance`; every key, default, and clamp range is
declared in [`Defaults.Overlay`](../Sources/JarvisCore/Config/Defaults.swift). Each surface carries an
on/off flag, a font size, and an opacity; the box additionally carries its width and height.

The two surfaces default opposite ways — the caption **off**, the box **on** — so a first run shows
the durable history rather than a flashing caption. `AppDelegate` applies both enabled flags at launch.

The box is a **session surface**: switched on, it reaches the screen on Start (already cleared, for the
new conversation) and leaves it on Stop, so a stopped Jarvis puts nothing on the desktop. Two flags in
`OverlayBoxPanel` decide it — the Settings switch (`setEnabled`) and the session (`setSessionLive`,
called by `AppDelegate` from the one line that declares a session live and the one that ends it) — and
a single private `applyVisibility()` derives `isEnabled && isSessionLive`. Keeping that rule in one
place is why the panel, not the two call sites, owns it: switching the box on from Settings while
stopped would otherwise leave it on screen with no session behind it. The Settings preview overrides
the rule while the Overlay tab is open and re-derives it on close.

The session’s selected interview format appears beside the name in the box’s existing header
(for example, **Jarvis · Coding**). It uses the same Start-time selection as the coaching prompt,
remains visible when collapsed, and survives clearing responses. With no selection or after Stop,
the title reads **Jarvis**. The format shares the header’s sizing and adds no extra row.

Opacity governs the background fill only, so both surfaces accept 0%: a text-only surface with no
backdrop, not a hidden one. Nothing here takes a surface off screen: that is the On/Off toggle, and
for the box the end of a session as well. Both share one range because the tab presents their
sliders identically. A corrupted non-finite stored value restores the setting's own default rather
than the range floor, which at 0% would read as breakage.

The box's **Show diagrams** switch controls [private architecture hints](./architecture.md#private-architecture-hints).
It defaults on, persists across launches, and immediately hides or restores graph attachments while
keeping their text hints and history. Graphs scale proportionally to fit the available window width
and the renderer's height budget, leaving room for text; resizing updates the image during the drag
without writing preferences until the drag ends.

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
is running. A surface's live sample is shown only while the Overlay tab is selected **and that
surface is on** — `didBecomeActive` previews each surface for its enabled state, and flipping a
toggle shows/hides that surface's sample (and collapses/expands its sliders via `relayout()`) live.
Each panel's `showAppearancePreview(_:)` re-asserts capture exclusion so the preview stays hidden
from screen capture — same defense-in-depth as the coaching display path. The box's preview shows
sample text without disturbing the real log and re-derives `isEnabled && isSessionLive` on close, so
closing the tab can leave the box on screen only while both hold. The box's sample stands in **only
while stopped**: during a session the box is already on screen carrying the conversation's own tips
and the sliders apply to it live, so a sample would replace real content with something worse. That
boundary is a correctness one as much as a display one, because it is what guarantees no tip can land
behind a sample and no collapse snapshot can cross a session boundary. Start therefore takes the
sample down.

Settings cannot see the session, so `showAppearancePreview(_:)` records a request rather than
obeying one, the way `setEnabled(_:)` does: the sample shows when Settings wants it **and** no session
is running, derived in one place. A request made during a session is still standing when the session
stops, so a Stop taken without leaving the tab brings the sample up rather than leaving the sliders
with nothing on screen to act on. Which source is showing is a value, `Display.log` or `.sample`, and
the readout and the clear button are derived from it together rather than each asking whether a
preview is running. The plain setters
(`setFontSize`/`setBackgroundOpacity`/`setOpacity`) only change appearance and don't touch
`sharingType`. See [overlay-invisibility.md](./overlay-invisibility.md).

## Shortcuts

**Give me a hint** defaults to **⌥⌘J**, **Explain more** to **⌥⌘E**, and **Show code** to **⌥⌘K**.
They work during a session; code is available in Coding and general sessions only. Hints and
explanations are fallbacks for proactive coaching; the code hotkey requests a snippet only when the session started with code enabled; [architecture.md](./architecture.md#on-demand-coaching-shortcuts)
defines their context, output, and scheduling behavior. Each card uses `HotkeyBindingView` and the
existing recorder, requiring Command or Option. A successful rebind takes effect immediately and
persists only that shortcut through `HotkeyPreferences`; defaults and storage keys live in
`Defaults.Hotkey`. Escape cancels recording.

The **Explain more** card includes **Enable explanations**, on by default. Switching it off hides
its shortcut recorder and releases the global key while preserving the chosen combination.
Switching it on shows the recorder and saves the combination for the next Start. During a session
that started without explanations, neither enabling the setting nor rebinding registers a usable
explanation shortcut. Automatic explanations remain available for an enabled session even if its
shortcut cannot register. `ExplanationPreferences` persists the switch; the capability is frozen at
Start. The row says “Takes effect the next time you start.” Disabling Overlay Box also disables the
saved explanation setting and its switch remains unavailable until the box is enabled again.
Ordinary hints remain available. Enabling explanations makes them available for explicit requests
or clear gaps in understanding; routine next steps, local corrections, and code snippets default to
no explanation. The explanation length guidance applies only after that need is established.

A collision with another application or another Jarvis shortcut leaves the old working binding
active and displays feedback for that card. If no binding could be registered at launch, its warning
persists across tab visits. The three cards scroll at small window sizes, including when registration warnings
are visible. Resizing or changing a binding card preserves the reading offset, clamped to the available
content. The Overlay Box distinguishes semibold hints from regular explanation paragraphs with an
**Explanation** label and spacing. Both bodies use the configured text size; the appearance preview
shows an example. Neither surface's visibility preference changes.

The **Show code** card includes **Show code with hints**, off by default, persisted by
`CodePreferences`. It is captured at Start: enabled coding/general sessions reserve the
[dedicated code area](./architecture.md#on-demand-coaching-shortcuts) and request matching snippets
alongside hints. Saved changes affect the next Start; they do not alter the active dock or prompt.
The hotkey requests the next snippet only for a session that started with code enabled. Turning the
setting off hides its recorder and releases the binding; enabling or rebinding during a disabled
session leaves the shortcut deferred until Start. Code remains independent of **Enable explanations**.
Both features require Overlay Box; switching the box off also disables their saved settings,
releases their shortcuts, and clears/disables the live code dock. Re-enabling the box alone does not
restore code; enable code before the next Start. The rows show the dependency. No shortcut enables the master box.

## Activity response sections

Each new coaching response retains its delivered **Hint**, optional **Explanation**, and optional
**Code** as separate fields through `ActivityResponse`. The Activity feed labels each present part;
code keeps its indentation in a monospace block with language and placement guidance. The same
sections survive live replay, reopening a saved session, and Markdown, plain-text, or HTML export.
The recorder includes only explanation and code actually accepted by the overlay.

Existing sessions without structured response fields display their original messages. Activity does
not guess boundaries from old flattened prose. New records also retain a readable text message for
older readers and the session evaluator; structured fields drive the sectioned viewer.

## Brain

The Brain tab owns the whole "who answers a coaching attempt" decision, persisted through
`BrainPreferences` (UserDefaults).

The page header sits above one vertically scrolling stack of three rounded groups: **Provider
route**, **Coaching**, then **Transcription**. The Provider group is one uninterrupted route: Primary and every
Fallback row share the same label / provider / model alignment, with ordering actions only on
fallbacks. There are no row dividers or permanent explanatory paragraphs. Fallback rows expand the
outer document instead of hiding inside a second scroll area. While coaching runs, a compact **In
use** marker exposes the runtime cursor without moving or rewriting any saved target.

**Primary.** The first row selects a provider and model: the **OpenAI API** (metered by the key), or a
locally installed **Claude Code** / **Codex CLI**. Claude uses a session-scoped local runtime for
coaching on the user's existing Claude *subscription* instead of the key, and Codex likewise coaches
through a session-scoped app-server on the user's ChatGPT subscription (`CLIBrainClient`; see
[architecture.md](./architecture.md#local-cli-brain-providers)). Installed CLIs are auto-detected by `AgentCLIDetector`: binary
discovery is a pure file probe over $PATH + the known install dirs, while Claude sign-in uses its
non-billing `auth status --json` command under a short timeout because account metadata can outlive
an expired OAuth session. Codex keeps using its auth-file marker and a bounded capability probe.
Settings runs these probes asynchronously and keeps local-provider controls selectable while the
first result is pending. After detection, the route menus show provider names only and omit
confirmed-missing, signed-out, or otherwise unselectable alternatives; Connections owns provider
status text. An unavailable auth probe does not falsely claim logout. An empty, failed, or changed
Codex feature catalog only narrows the disable flags that are passed; it never widens what a
coaching thread may do.

A fresh install opens on the **OpenAI API** as Primary, so the Brain tab always shows a complete,
usable route and Start never fails for want of a provider choice. That default costs the user nothing
extra: transcription defaults to OpenAI too, so the same one credential covers both, and a user who
wants a subscription-backed CLI brain changes Primary and Transcription in one visit. There is no
"unconfigured" state — the saved route is always complete.

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

Confirmed-missing or signed-out targets are hidden from new selection while editing; an existing
saved row stays visible so the user can repair or remove it. If a configured fallback becomes
unavailable after Start, activation skips it and moves forward without inventing provider requests
solely to consume the failure budget. Runtime movement through the route never changes the saved
list. Stop → Start begins at the saved primary again.

**Model + reasoning effort.** A **Model** dropdown is drawn from `BrainModelCatalog` per provider.
OpenAI API and Codex CLI share one concrete model list; Claude Code exposes the current concrete
release in each supported family. Concrete releases, never rolling aliases such as `sonnet` or
`opus` or a CLI's own default: a saved route must keep naming the release the user picked, and an
alias silently retargets it the day the provider advances it. Each provider remembers its own model; without a valid preference,
the first entry in that provider's catalog is selected. The **Reasoning effort** picker
(`ReasoningEffort`: None / Low / Medium / High) is stored once and applies uniformly to whichever
provider is active; its default lives with the others in
[`Defaults.Brain`](../Sources/JarvisCore/Config/Defaults.swift). `CLIBrainClient` maps it onto Claude Code's `--effort` and Codex's
per-thread `model_reasoning_effort`; both CLI scales start at `low`, so None clamps to Low while the
three shared levels pass through.

**Interview format.** The Coaching-card picker defaults to **None** (base prompt only), with
**Coding**, **Behavioral**, **System Design**, and **General Technical** as explicit selections.
The selected addendum applies on the next Start. General Technical uses available conversation and
screen context; capture remains on demand. Per-format policy and the explicit System Design
requirement for diagrams are defined in [architecture.md → Models and APIs](./architecture.md#models-and-apis).

**Transcription.** This group owns the separate speech-to-text role without conflating it with the
brain route. Its picker contains **OpenAI** (the default), **Gemini**, and **Apple Speech (macOS
26+)**. Apple is enabled only when the running Mac and OS expose `SpeechTranscriber`; selecting any
provider persists through `TranscriptionPreferences` and applies on the next Start, never halfway
through a live session. `TranscriptionControls` shows one fixed row set per provider — the provider
row plus only that provider's rows (`visibleRows`) — so switching providers never leaves a stale
control from the previous choice visible.

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
pipeline. Apple Speech uses one locale for the whole session, so Settings explicitly recommends
OpenAI for English/Mandarin code-switching. Jarvis does not run parallel Apple transcribers, and the
runtime never falls back to OpenAI implicitly if the Apple analyzer fails.

Reads are validated: a persisted primary model id no longer in that provider's catalog uses the
provider default without rewriting the invalid value, while invalid fallback rows are removed during
route normalization. An unrecognized provider/effort likewise uses its existing default rather than
reaching the API. Transcription preferences are validated independently: unknown OpenAI model ids
use GPT-4o; unknown or duplicate expected-language values are discarded and the remaining values use
stable declaration order; an empty list means Automatic. Gemini's model, expected languages,
vocabulary, and mode each fall back to their own default the same way on an unrecognized stored
value. Existing fixed-profile preferences are read
into the matching list until the user edits it. An unsupported Apple locale fails visibly at Start
rather than choosing a different language. A running `CoachDriver` applies valid brain edits
atomically at the coaching-attempt boundary while transcript, client-managed history, audio
pipeline, and session logs continue unchanged. A provider, model, or route-order edit replaces the route for the next
attempt and resets the session-local cursor to the newly selected primary. The new active local
runtime begins preparing immediately; ready or in-flight processes owned only by the superseded
route are terminated. This topology edit is the only way to revisit a target that
automatic failover left behind. The old active provider is not retained as a hidden fallback; it
remains available only when the user includes it in the new list.

A reasoning-effort edit instead rebuilds the clients at the current forward-only cursor and preserves
its failure counts. An attempt already in flight keeps its snapshotted client and remains
authoritative: its success or failure updates route health normally, and the new effort begins with
the next attempt. The replacement at the preserved active cursor—whether primary or fallback—starts
preparing immediately; replacements behind that cursor are terminated without being prepared.

A local-CLI target is preflighted first. A confirmed missing binary or signed-out account cannot
activate; the running route stays intact and Activity records fixed settings-not-applied copy.
Provider-specific partial tool-loop state from a failed attempt is discarded, while provider-neutral
pending conversation follows the newly installed route on its next attempt. While stopped, persisted
changes apply on the **next Start**. Runtime readiness is not a routing signal: if Claude's ready
query or Codex's app-server is unavailable, that provider attempt fails and follows the normal
fresh-attempt route policy. Neither CLI ever falls back to a one-shot command.

Brain-route choices persist via `BrainPreferences`, while the independent transcription provider,
OpenAI model/expected-language list, and Apple locale persist via `TranscriptionPreferences`. Those
types own validation and normalization; every key and default value they read comes from
[`Defaults`](../Sources/JarvisCore/Config/Defaults.swift), and the per-provider model lists from
`Sources/JarvisCore/Brain/BrainModelCatalog.swift`.

## Connections

The Connections tab owns authentication shared across Brain and Transcription. Its four stacked
cards are **OpenAI API**, **Gemini API**, **Claude Code**, and **Codex CLI**. The OpenAI and Gemini
cards each report and edit only their own Jarvis-managed owner-only file through `APIKeyControls`
(one instance per `Credential`, keyed by `credential.rawValue` so their accessibility labels,
identifiers, and saved-key state never collide); each card's action is **Add API key** or **Edit**.
The `OPENAI_API_KEY` fallback remains usable by Start but is deliberately not presented as a
Jarvis-managed saved key; Gemini has the same headless fallback in `GEMINI_API_KEY`
(`Credential.geminiAPIKey.environmentVariable`, read by `EnvSecretStore`), also not presented as a
saved key.

Claude Code and Codex CLI keep authentication in their own tools. Connections runs the existing
bounded `AgentCLIDetector` probes and reports **Signed in**, **Signed out**, **Sign-in unknown**, or
**Not installed** without opening a login flow or storing another secret. The page's compact ready
count includes every managed API key that is saved and confirmed signed-in local accounts.

An OpenAI key is required only when OpenAI is selected for transcription or appears anywhere in the
brain route; a Gemini key is required only when Gemini is selected for transcription — Gemini is not
a brain provider. Apple Speech plus a CLI-only route can start without either key. Saving a managed
key while a session runs preserves route health: an OpenAI save refreshes both the OpenAI brain
clients and a live OpenAI transcription socket's future reconnect credential, while a Gemini save
refreshes only a live Gemini transcription socket's future reconnect credential. Neither ever probes
or replaces a CLI client, and a saved credential only ever reaches the transcriber built for that same
provider.

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
deciphering pixels. OCR, not accessibility-tree extraction: Chrome exposes web content only under
assistive-tech flags and Monaco virtualizes to the visible lines, so OCR gets the same text
generically with none of the per-app fragility. Nor is the text a substitute for the image, which
stays ground truth: diagrams and layout need vision, and OCR mangles the odd identifier. Nothing eligible on screen → fall back to a full shot of the **main display**;
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
from an old entire-display selection never steers them. A transient-file cleanup failure is not an
ordinary capture failure: it poisons the session-local runner and returns without a window/display
fallback or a later capture.

Both values, their keys, and the main-display floor are declared in
[`Defaults.Screen`](../Sources/JarvisCore/Config/Defaults.swift).

## Key Files

| File | Role |
|---|---|
| `Sources/JarvisApp/Settings/SettingsSection.swift` | Protocol definition |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | Host window + tab view |
| `Sources/JarvisApp/Settings/SettingsStyle.swift` | Shared page/card/row sizing and spacing tokens |
| `Sources/JarvisApp/Settings/SettingsPageView.swift` | Full-tab page title, summary, status, and content shell |
| `Sources/JarvisApp/Settings/SettingsCardView.swift` | Rounded group boundary, optional header, and resize callback |
| `Sources/JarvisApp/Settings/SettingsRowView.swift` | Shared label/help/trailing-control row |
| `Sources/JarvisApp/Settings/SettingsScrollView.swift` | Viewport-change adapter for variable-height card documents |
| `Sources/JarvisApp/Settings/BrainSection.swift` | Minimal Brain tab composition: Provider + Reasoning effort + Interview format + Transcription |
| `Sources/JarvisApp/Settings/ConnectionsSection.swift` | Per-credential API-key editors (OpenAI, Gemini) + external CLI account readiness |
| `Sources/JarvisApp/Settings/BrainTargetRowView.swift` | Shared inline provider/model row for primary and fallback targets |
| `Sources/JarvisApp/Settings/ProviderRouteEditor.swift` | Unified Primary + ordered fallback card and persistence mutations |
| `Sources/JarvisApp/Settings/TranscriptionControls.swift` | Transcription provider/model/language-or-locale behavior card |
| `Sources/JarvisApp/Settings/ExpectedLanguagePicker.swift` | Scalable expected-language chips + multi-select popover |
| `Sources/JarvisApp/Settings/APIKeyControls.swift` | Collapsed Jarvis-managed API-key editor, one instance per `Credential` |
| `Sources/JarvisCore/Transcription/TranscriptionProvider.swift` | Provider identities, labels, per-provider credential + audio format |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | Overlay-appearance tab |
| `Sources/JarvisApp/Settings/OverlaySurfaceSettingsView.swift` | One reusable overlay-surface card and its slider/readout rows |
| `Sources/JarvisApp/Settings/DisplaySection.swift` | Capture-scope tab (scope + display in one dropdown) |
| `Sources/JarvisApp/Settings/NSScreen+DisplayTitles.swift` | Display naming for the dropdown's entire-display entries |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | Activity tab |
| `Sources/JarvisCore/Brain/BrainProvider.swift` | The three providers |
| `Sources/JarvisCore/Brain/Adapters/LocalAgent/AgentCLIDetector.swift` | CLI binary discovery + bounded authentication-status detection |
| `Sources/JarvisCore/Brain/BrainModelCatalog.swift` | Curated per-provider model lists (`BrainModel`) |
| `Sources/JarvisCore/Brain/ReasoningEffort.swift` | The four effort levels |
| `Sources/JarvisEvaluation/AgenticEvaluator.swift` | Read-only Claude Code / Codex session audit invoked by Activity and `EvalPrep` |
| `Sources/JarvisCore/Config/Defaults.swift` | Every user setting's key, default, and valid range |
| `Sources/JarvisCore/Config/BrainPreferences.swift` | UserDefaults persistence + route validation |
| `Sources/JarvisCore/Coach/CoachDriver.swift` | Between-attempt route application and attempt orchestration |
| `Sources/JarvisCore/Config/ScreenCapturePreferences.swift` | Capture scope + display persistence + clamping |
| `Sources/JarvisScreenCapture/ScreenCaptureCLI.swift` | `ScreenCaptureCLI` — reads the selection at capture time, falls back to the main display |
| `Sources/JarvisCore/Overlay/OverlayAppearance.swift` | UserDefaults persistence; `OverlayCaptionApplying` + `OverlayBoxApplying` protocols |
| `Sources/JarvisCore/Config/TranscriptionPreferences.swift` | Persisted transcription selection + validation |
| `Sources/JarvisCore/Overlay/BroadcastOverlay.swift` | Fans one `render` out to the caption + box |
| `Sources/JarvisOverlay/OverlayCaptionPanel.swift` | The Overlay Caption; `OverlayCaptionApplying` conformance |
| `Sources/JarvisOverlay/OverlayBoxPanel.swift` | The Overlay Box; `OverlayBoxApplying` conformance |
| `Sources/JarvisOverlay/NSPanel+CaptureExclusion.swift` | Shared `sharingType = .none` helper for both panels |

## Related Pages

- [overlay-invisibility.md](./overlay-invisibility.md) — capture exclusion re-assert during preview
- [build-and-run.md](./build-and-run.md) — the embedded activity log
