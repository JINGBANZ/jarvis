# Dev Activity Viewer — Design

> Design page for the dev-mode activity viewer: an in-app live log window with a screenshot
> lightbox and browsable session history. Dev-mode only. Supersedes the original
> `file://` + `<meta refresh>` HTML viewer described historically in [sandbox.md](./sandbox.md).

## Why

The first viewer wrote a self-contained `jarvis-activity.html` at `0600` and opened it in the
user's default browser, hard-reloading every second via `<meta http-equiv="refresh">`. That reload
is poor UX (flicker, lost scroll/modal state) and untestable — tests could only assert on the
rendered HTML *string*, never the actual behaviour. We also want to **watch past sessions**, not
just the live one, and a one-click way to **clear old session history**.

Quality bar: even though this is dev-only, it should be production-grade — live, flicker-free,
end-to-end tested. Security is a non-concern in dev mode beyond cheap hygiene (owner-only files).

## Goals

- Live, **no full-page reload** — new log lines append into the DOM as they arrive.
- Click a screenshot thumbnail → **in-page modal** (lightbox), not a new tab.
- **Session history**: browse and view previous dev sessions, not only the current one.
- **Clear history** button: delete all past session directories (keeping the live one).
- **Verifiable end-to-end** with automated tests, no new third-party dependency.

## Approach (decided)

In-app `WKWebView` window with Swift **pushing** updates, chosen over a local HTTP server + SSE.
For a Mac app that already holds the log entries in memory, pushing them into an embedded WebView
is less code, has zero network surface, and is the most testable (the production runtime *is* the
test runtime). No new dependency — `WebKit` is a system framework.

`<meta refresh>` could not simply be replaced by `fetch()`-polling because browsers block
`fetch()` of local files from a `file://` page — which is *why* the original used meta-refresh.
Pushing into an embedded WebView sidesteps the `file://` limitation entirely.

## Architecture

```
jlog(msg, image)
  └─> ActivityLog.shared.record()            [JarvisCore, serial queue]
        • append Entry (DOM render cap = maxLines)
        • persist: append <session>/jarvis-activity.jsonl line  (+ write shot-N.jpg)
        • notify observer with a JS snippet:  appendRow({...})   (image as in-memory data: URI)
  └─> ActivityViewer                          [JarvisApp, @MainActor]
        • DispatchQueue.main.async { webView.evaluateJavaScript(snippet) }
  └─> page JS: appendRow(payload) builds one row node and appends it
```

- **No reload, no flicker, no server, no port.**
- The **live** view never touches the filesystem: screenshots are pushed as in-memory
  `data:image/jpeg;base64,…` URIs built from the bytes already in hand at `record()` time.
- **History** view: `SessionStore` reads a session's `.jsonl` + `.jpg` files in Swift, hydrates
  them into `data:` URIs, and pushes them through the *same* `appendRow` path.

## Persistence

Refines the earlier "drop on-disk files" decision: we drop the rendered **HTML** file and the
meta-refresh, but **persist structured data** so past sessions survive an app quit. This is added
to the per-session directory that already exists and is already persistent + owner-only.

Per-session directory (`<base>/<yyyy-MM-dd_HH-mm-ss>_<id>/`, `0700`; see `AppDelegate`):

| File | Contents | Perms |
|------|----------|-------|
| `jarvis-activity.jsonl` | append-only, one entry per line: `{"t":"HH:mm:ss","m":"…","s":"shot-3.jpg"?}` | `0600` |
| `shot-N.jpg` | screenshot bytes, referenced by `s` | `0600` |
| `jarvis-debug.log` | (unchanged) `JarvisLog`'s debug log | `0600` |

`t` = time, `m` = message, `s` = optional shot filename. Colour class is **not** persisted — it is
recomputed from `m` via `cssClass` on read. The full session is persisted (append-only); the **DOM
render is capped** at `maxLines` (most-recent). To show "showing last N of M" without silent
truncation, the true total **M** must be tracked separately from the `maxLines`-capped in-memory
`entries` (which `record()` trims): `ActivityLog` keeps a running `totalCount`, and for past
sessions `M` is the `.jsonl` line count. Write ordering is **`shot-N.jpg` first, then the `.jsonl`
line** that references it, so a referenced shot always exists; a crash between the two at worst
leaves an orphan `.jpg` (harmless), never a dangling reference.

## Components

### `ActivityLog` (JarvisCore — model, no AppKit/WebKit)

- `enable(directory:)` / `disable()` — `directory` is the current session dir. `enable()` **creates
  the (empty) `jarvis-activity.jsonl` immediately** so the live session is discoverable by
  `listSessions()` before its first `record()` (see Persistence).
- `record(message:imageBase64:at:)` — append in-memory Entry; **increment a running `totalCount`**
  (kept separately from the `maxLines`-capped `entries`, so the true total survives the cap — see
  "N of M"); **write `shot-N.jpg` first, then append the `.jsonl` line referencing it** (so a
  referenced file always exists on disk); then notify the observer with the live row.
- `attach(onAppend:) -> Snapshot` — **atomically** (under the serial queue) sets the observer *and*
  returns a `Snapshot { shellHTML: String, rows: [String] }`: the **empty** `htmlShell()` plus the
  current entries already encoded as `appendRow(...)` snippets to replay. This is the cut point —
  every subsequent entry arrives via `onAppend` exactly once, never double-rendered or missed.
  `onAppend` may be called on any thread; the caller is responsible for hopping to the main thread.
  **One render path only:** both the snapshot rows and live rows are `appendRow(...)` snippets — no
  server-side row HTML, so `esc()` is genuinely gone (see Rendering & safety).
- Pure, testable helpers: `htmlShell()`, `rowScript(for: Entry, imageBase64: String?) -> String`
  (returns `appendRow(<json>)`; the image bytes are passed in — the live path has them in hand, the
  history path gets them from `SessionStore` — because `Entry.imageFile` is only the on-disk
  reference, not the bytes the DOM consumes), `cssClass(for:)`.

### `SessionStore` (JarvisCore — Foundation only)

Given the **base** log directory and the current session dir:

- `listSessions() -> [Session]` — **immediate subdirectories** of the base whose name matches the
  session-id shape (`yyyy-MM-dd_HH-mm-ss_xxxx`) and that contain a `jarvis-activity.jsonl`,
  newest-first, labelled by the timestamp parsed from the dir name, current session flagged. Since
  `enable()` creates an empty `.jsonl`, the live session always appears (even before its first
  entry).
- `entries(for:) -> [(Entry, Data?)]` — decode a session's `.jsonl`; for each `s`, **validate it is
  a bare `shot-N.jpg` filename** (reject anything containing `/`, `..`, or that resolves outside the
  session dir — path-traversal guard) and read its bytes. Malformed/partial lines are skipped; a
  missing/unreadable/invalid shot degrades to a **text-only row** (the line still renders). The
  caller builds `data:` URIs from the bytes; colour `cls` is **recomputed from the message** via
  `cssClass` on read (it is not persisted).
- `clearHistory()` — delete only **immediate subdirectories of the known base dir** that match the
  session-id shape, **except** the current session, and **without following symlinks**. Never
  deletes the base itself or anything outside it.

### `ActivityViewer` (JarvisApp — `@MainActor`, thin)

- Owns one `NSWindow` + `WKWebView` + a header bar holding a **session picker**
  (`NSPopUpButton` — least code, no split-view) + a **Clear history** button.
- **`WKWebView` configuration (defense-in-depth):** loaded only via `loadHTMLString`; the navigation
  delegate **denies every navigation except the initial `about:blank`/in-memory load** (any
  `data:`/link click/redirect is cancelled), so pushed screen-derived text or a `data:` image can't
  navigate out or exfiltrate. No network is needed or permitted.
- **`show()`** — lazily create the window; reopen brings it forward. Because the app runs as
  `.accessory`, `show()` must **promote activation** so the window becomes key and front — follow
  the existing pattern in `MenuBarController`/`AppDelegate` (`NSApp.activate(...)`, temporary
  `.regular` policy), otherwise the window opens behind everything.
- **Live (current) session** → `attach` to `ActivityLog`, `loadHTMLString(snapshot.shellHTML)`,
  replay `snapshot.rows`, wire `onAppend`. **Buffering contract:** `onAppend` hops to the main
  thread and appends to a **main-thread-confined pending buffer**; before `didFinish` nothing is
  evaluated; on `didFinish` the snapshot rows render first, then the buffer drains **FIFO**, then a
  `loaded` flag flips so later snippets evaluate immediately — no interleaving, no loss (the
  `attach` snapshot is the cut point).
- **Past session** → detach the live observer, then static-load: `SessionStore.entries(for:)` →
  `appendRow` each (text-only row when a shot is missing/invalid).
- **State transitions (defined):** first open → show the live session; switching past→live →
  re-`attach` and re-snapshot; selecting a session that no longer exists (e.g. just cleared) →
  fall back to the live session; reopen after window close → recreate and re-snapshot.
- **Clear history** → confirmation dialog (destructive, irreversible) → `SessionStore.clearHistory()`
  → refresh the picker (and fall back to live if the viewed session was deleted). Deletes the entire
  past-session directories (activity, screenshots, **and** their debug logs), keeping only the live
  session.

### Wiring (`AppDelegate`, `MenuBarController`)

- Dev mode: `ActivityLog.shared.enable(directory: sessionDir)` (as today) and construct
  `SessionStore(base: devLogDirectory(), current: sessionDir)`.
- The menu's **Open Log Viewer** calls `viewer.show()` instead of `NSWorkspace.open(url)`.

## Rendering & safety

One rendering path: both the initial snapshot and live updates go through the JS
`appendRow(payload)`. The payload is a **JSON object** (`{cls, time, message, img}`); JS sets text
via `textContent` and the image via `img.src`. Therefore:

- **No manual HTML escaping** — JSON encoding handles the JS-string boundary, `textContent` the DOM
  boundary. XSS-safe by construction; the hand-rolled `esc()` is removed.
- The lightbox modal stays (click thumbnail → overlay; Escape / backdrop closes) but **without the
  `sessionStorage` survival hack** — with no reload, the modal simply lives in the DOM.

## Image size

Screenshots come from the existing capture pipeline already encoded as JPEG and pushed as `data:`
URIs via `evaluateJavaScript`. This is acceptable for a dev tool, but to bound `evaluateJavaScript`
payload size and DOM memory — especially when hydrating a past session — the viewer renders at most
`maxLines` rows, and screenshots are kept at their captured JPEG size (no full-resolution PNG). If a
specific session proves heavy in practice, downscaling at `record()` time is the follow-up lever;
not pre-optimised here (YAGNI).

## Removed

`<meta refresh>`, the `sessionStorage` scroll+modal hack, `esc()`, the rendered `jarvis-activity.html`
file, `htmlURL`, `renderHTML`, the `JARVIS_ACTIVITY_HTML` env override, and the `NSWorkspace.open`
browser flow. **Reconciliation:** the existing `ActivityLogTests` that assert on `renderHTML`/`esc`/
`htmlURL`/`target="_blank"` are rewritten against the new surface; the headless **test-enable path**
that `JARVIS_ACTIVITY_HTML` provided is replaced by tests calling `enable(directory:)` with a temp
dir. `JarvisLog`'s debug-log file and `debugLogURL` are untouched.

## Testing

- **Pure unit tests** (`JarvisCoreTests`, no WebView): `cssClass` markers; `rowScript` JSON
  encoding (quotes/markup in messages; image present vs nil); `attach` snapshot + observer fires
  for subsequent records; `maxLines` cap.
- **`SessionStore` tests** (temp dirs): newest-first ordering; current-session flag; `clearHistory`
  deletes past dirs and spares the current; malformed `.jsonl` tolerated.
- **Round-trip**: `record()` writes a `.jsonl` line + `.jpg`; re-reading via `SessionStore`
  reproduces the entry.
- **End-to-end** (a **dedicated `JarvisViewerTests` target** that `import WebKit`, `@MainActor` — kept
  out of `JarvisCoreTests` so the core's own test target stays Foundation-only and the "UI-free"
  boundary holds literally; add the target in `Package.swift`): a real `WKWebView` loads the
  shipped HTML and runs the **actual shipped JS**, driven through the same `ActivityLog` /
  `SessionStore` API the production controller uses. The async harness uses a navigation-delegate
  continuation with a **per-test timeout and a double-resume guard** (so a load failure fails the
  test instead of hanging CI) —
  - `appendRow` with a message containing `<script>`/quotes → the row's displayed text equals the
    raw message and no element was injected (XSS-safe, end-to-end);
  - `appendRow` with an image → `a.shot img` src is the data URI;
  - dispatch a click on `.shot` → `#lightbox.open` and `#lightbox-img` src match;
  - dispatch Escape / backdrop click → modal closed;
  - loading a past session's entries renders its rows.
- **Manual `/verify`**: run the real app in dev mode, open the viewer, confirm live append, modal,
  session switching, and clear-history.

## Risk: headless WKWebView in `swift test` — validated

The one real risk was whether `WKWebView` can run headless under `swift test` (no `NSApplication`,
the main run loop must pump navigation). **This was empirically confirmed on the target CLT-only
machine** during review: a minimal SPM package whose test target `import WebKit` and drives a real
`WKWebView` from a `@MainActor @Suite` async test (navigation-delegate continuation + async
`evaluateJavaScript`), launched via the exact `scripts/run-tests.sh` CLT framework-search-path
flags, compiled, linked, and passed with no `NSApplication` and no manual run-loop pumping
(swift-testing's runner pumps the main run loop itself); synthetic DOM `click` and `Escape`
`KeyboardEvent` dispatch exercised the lightbox handlers end-to-end. So the harness is known-good;
the first implementation step still stands up a trivial-page smoke test in `JarvisViewerTests` to
lock it in. The dual-toolchain flag dependency (CLT vs full Xcode) is load-bearing for this target —
`run-tests.sh` already encodes it; CI runs full Xcode where plain `swift test` resolves WebKit.
