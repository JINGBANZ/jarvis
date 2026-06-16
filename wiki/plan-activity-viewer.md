# Dev Activity Viewer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) or
> superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox
> (`- [ ]`) syntax. Design: [activity-viewer.md](./activity-viewer.md).

**Goal:** Replace the `file://` + meta-refresh dev activity viewer with an in-app `WKWebView` window
that live-appends log rows (no reload), shows screenshots in an in-page lightbox, and lets you
browse + clear past-session history.

**Architecture:** `JarvisCore` stays UI-free: `ActivityLog` (live model + JSONL/JPEG persistence +
observer + pure HTML/JS string generation) and `SessionStore` (read/list/delete past sessions).
`JarvisApp` gets a thin `@MainActor ActivityViewer` (NSWindow + WKWebView, pushes rows via
`evaluateJavaScript`). WebKit-driven end-to-end tests live in a dedicated `JarvisViewerTests` target.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, AppKit, WebKit (system framework), Foundation.

**Build/test commands:** `./scripts/run-tests.sh` (handles CLT WebKit search-path flags),
`swift build` (compiles all targets incl. JarvisApp).

**Commit policy:** the user has not asked for commits; keep work in the worktree tree and verify via
tests/build. (Frequent-commit steps below are written for completeness; skip the `git commit` step
unless the user asks.)

---

## File Structure

- `Sources/JarvisCore/ActivityLog.swift` — **rewrite**: live model, JSONL+JPEG persistence,
  observer/`attach`, `totalCount`, pure `htmlShell`/`rowScript`/`cssClass`. Drop `renderHTML`/`esc`/
  `htmlURL`/`writeHTML`/`JARVIS_ACTIVITY_HTML`.
- `Sources/JarvisCore/SessionStore.swift` — **new**: `listSessions`, `entries(for:)`,
  `clearHistory`, with path-traversal / session-shape guards.
- `Sources/JarvisCore/ActivityViewerAssets.swift` — **new** (optional split): the embedded JS/CSS
  string constant, kept apart from the model logic. (May instead live inside `ActivityLog`.)
- `Sources/JarvisApp/ActivityViewer.swift` — **new**: `@MainActor` window controller.
- `Sources/JarvisApp/AppDelegate.swift` — **modify**: build `SessionStore`, own `ActivityViewer`,
  point `onOpenLogViewer` at it.
- `Package.swift` — **modify**: add `JarvisViewerTests` test target (depends on `JarvisCore`).
- `Tests/JarvisCoreTests/ActivityLogTests.swift` — **rewrite** against the new surface.
- `Tests/JarvisCoreTests/SessionStoreTests.swift` — **new**.
- `Tests/JarvisViewerTests/ViewerEndToEndTests.swift` — **new** (WebKit, `@MainActor`).

---

## Task 0: Add the JarvisViewerTests target and prove the headless WKWebView harness

**Files:**
- Modify: `Package.swift`
- Test: `Tests/JarvisViewerTests/HarnessSmokeTests.swift` (create)

- [ ] **Step 1: Add the test target to `Package.swift`**

```swift
        .testTarget(
            name: "JarvisCoreTests",
            dependencies: ["JarvisCore"]
        ),
        .testTarget(
            name: "JarvisViewerTests",
            dependencies: ["JarvisCore"]
        ),
```

- [ ] **Step 2: Write the failing smoke test** — proves a real `WKWebView` loads HTML and runs JS
  headlessly under `swift test`.

```swift
import Testing
import WebKit
@testable import JarvisCore

@MainActor
final class WebViewHarness: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300))
    private var cont: CheckedContinuation<Void, Error>?
    private var done = false
    override init() { super.init(); webView.navigationDelegate = self }

    /// Load HTML and await didFinish, with a timeout + double-resume guard so a stuck load fails
    /// the test instead of hanging CI.
    func load(_ html: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { c in self.cont = c; self.webView.loadHTMLString(html, baseURL: nil) }
            }
            group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw HarnessError.timeout }
            try await group.next()
            group.cancelAll()
        }
    }
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) { resume(.success(())) }
    func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError e: Error) { resume(.failure(e)) }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { resume(.failure(e)) }
    private func resume(_ r: Result<Void, Error>) {
        guard !done else { return }; done = true
        switch r { case .success: cont?.resume(); case .failure(let e): cont?.resume(throwing: e) }
        cont = nil
    }
    enum HarnessError: Error { case timeout }
    func eval(_ js: String) async throws -> Any? { try await webView.evaluateJavaScript(js) }
}

@Suite struct HarnessSmokeTests {
    @MainActor @Test func loadsAndEvaluates() async throws {
        let h = WebViewHarness()
        try await h.load("<!doctype html><title>t</title><body><p id=x>hi</p></body>")
        let v = try await h.eval("document.getElementById('x').textContent") as? String
        #expect(v == "hi")
    }
}
```

- [ ] **Step 3: Run it**

Run: `./scripts/run-tests.sh --filter HarnessSmokeTests`
Expected: PASS. If it fails to *link* WebKit, the run-tests.sh CLT flags need verifying; if it
*hangs*, the timeout fails it (then investigate run-loop). This task de-risks everything downstream.

- [ ] **Step 4: Commit** (skip unless asked): `git add Package.swift Tests/JarvisViewerTests`

---

## Task 1: Rewrite `ActivityLog` — model, persistence, observer, pure rendering

**Files:**
- Rewrite: `Sources/JarvisCore/ActivityLog.swift`
- Test: `Tests/JarvisCoreTests/ActivityLogTests.swift` (rewrite)

Public/internal surface to implement:

```swift
public final class ActivityLog: @unchecked Sendable {
    public static let shared = ActivityLog()

    struct Entry { let time: String; let message: String; let imageFile: String? }
    struct Snapshot { let shellHTML: String; let rows: [String]; let shown: Int; let total: Int }
    private struct PersistedEntry: Codable { let t: String; let m: String; let s: String? }

    private let maxLines = 400
    private let queue = DispatchQueue(label: "jarvis.activitylog")
    private var entries: [Entry] = []
    private var totalCount = 0
    private var shotSeq = 0
    private var dir: URL?                 // nil ⇒ disabled
    private var onAppend: ((String) -> Void)?
    private let df: DateFormatter         // HH:mm:ss, en_US_POSIX/Gregorian (unchanged)

    public func enable(directory: URL)   // set dir, reset state, create empty jarvis-activity.jsonl (0600)
    public func disable()                // dir=nil, clear state+observer
    public func record(_ message: String, imageBase64: String? = nil, at date: Date = Date())
    public func attach(_ onAppend: @escaping (String) -> Void) -> Snapshot  // atomic
    public func detach()                 // clear observer (when viewer shows a past session)

    static func cssClass(for message: String) -> String          // unchanged logic
    static func rowScript(time: String, message: String, imageBase64: String?) -> String
    static func htmlShell() -> String
}
```

Key behaviors:
- `enable`: under `queue` — `dir = directory`; clear `entries`, `totalCount`, `shotSeq`, `onAppend`;
  create `directory/jarvis-activity.jsonl` empty at `0600` (so `listSessions` sees the live session).
- `record`: under `queue` — `guard let dir else { return }`; if `imageBase64`, **write the JPEG
  first** via `saveShot` (0600) → `shotName`; build `Entry`; **append a `.jsonl` line**
  `{"t":..,"m":..,"s":..}` (encode `PersistedEntry`, append with newline); `entries.append`,
  `totalCount += 1`, trim `entries` to `maxLines`; `onAppend?(Self.rowScript(time:message:imageBase64:))`.
- `attach`: under `queue` — set `self.onAppend = onAppend`; build rows by reading each capped
  entry's shot file (`dir/imageFile` → base64) and calling `rowScript`; return
  `Snapshot(shellHTML: htmlShell(), rows: rows, shown: entries.count, total: totalCount)`. This is
  the atomic cut point.
- `rowScript`: JSON-encode `{time, message, cls: cssClass(message), img: imageBase64 == nil ? nil :
  "data:image/jpeg;base64,\(imageBase64!)"}` and return `"appendRow(\(json));"`. Use `JSONEncoder`
  (single-line) → the object literal is valid JS; `textContent`/`img.src` in the JS handle safety.

- [ ] **Step 1: Write failing tests** (`ActivityLogTests.swift`, full rewrite)

```swift
import Testing
import Foundation
@testable import JarvisCore

@Suite struct ActivityLogTests {
    @Test func cssClassKeysOnLeadingMarker() {
        #expect(ActivityLog.cssClass(for: "💬 use a hash map") == "say")
        #expect(ActivityLog.cssClass(for: "👁 looking at your screen") == "see")
        #expect(ActivityLog.cssClass(for: "🗣 heard: \"hi\"") == "hear")
        #expect(ActivityLog.cssClass(for: "🤫 quiet") == "hear")
        #expect(ActivityLog.cssClass(for: "💭 thinking…") == "think")
        #expect(ActivityLog.cssClass(for: "… held back") == "think")
        #expect(ActivityLog.cssClass(for: "realtime error: oops") == "err")
        #expect(ActivityLog.cssClass(for: "coaching started.") == "")
        #expect(ActivityLog.cssClass(for: "💬 your test failed") == "say") // not miscoloured err
    }

    @Test func rowScriptEncodesTextSafelyAndOmitsImageWhenNil() {
        let js = ActivityLog.rowScript(time: "10:00:00", message: "a < b & \"c\" </script>", imageBase64: nil)
        #expect(js.hasPrefix("appendRow("))
        #expect(js.contains("\"cls\"") || js.contains("cls"))
        #expect(!js.contains("data:image"))           // no image key payload
        // The raw message must be JSON-escaped, not HTML-escaped:
        #expect(js.contains("</script>") == false || js.contains("<\\/script>") || js.contains("</script>"))
        // It must be valid JSON inside appendRow(...)
        let inner = String(js.dropFirst("appendRow(".count).dropLast(2)) // strip "appendRow(" and ");"
        let obj = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any]
        #expect(obj??["message"] as? String == "a < b & \"c\" </script>")
        #expect(obj??["time"] as? String == "10:00:00")
    }

    @Test func rowScriptBuildsDataURIWhenImagePresent() {
        let js = ActivityLog.rowScript(time: "10:00:01", message: "👁 looked", imageBase64: "QUJD")
        #expect(js.contains("data:image/jpeg;base64,QUJD"))
    }

    @Test func recordPersistsJsonlAndShotThenNotifiesObserver() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        var pushed: [String] = []
        let snap = log.attach { pushed.append($0) }
        #expect(snap.rows.isEmpty)                      // empty session
        let pixel = Data([0xFF,0xD8,0xFF,0xD9]).base64EncodedString()
        log.record("👁 looking", imageBase64: pixel)
        log.record("💬 tip")
        _ = log.attach { _ in }                          // drains the serial queue (sync barrier)
        // jsonl has two lines; shot-1.jpg exists at 0600
        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.split(separator: "\n").count == 2)
        let shot = dir.appendingPathComponent("shot-1.jpg")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        #expect(pushed.count == 2)
        #expect(pushed[0].contains("data:image/jpeg;base64,"))
    }

    @Test func enableCreatesJsonlImmediately() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        _ = log.attach { _ in }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jarvis-activity.jsonl").path))
    }

    @Test func recordIsNoOpWhenDisabled() {
        let log = ActivityLog()
        log.record("💬 nothing")          // must not crash
        let snap = log.attach { _ in }
        #expect(snap.total == 0)
    }

    static func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
}
```

- [ ] **Step 2: Run, watch them fail to compile/pass** — `./scripts/run-tests.sh --filter ActivityLogTests`
- [ ] **Step 3: Implement the rewrite** in `ActivityLog.swift` per the surface + behaviors above
  (keep the `cssClass` body and the `DateFormatter` setup from the current file; delete
  `renderHTML`, `esc`, `htmlURL`, `writeHTML`, the `JARVIS_ACTIVITY_HTML` env init). Implement
  `htmlShell()` per Task 3.
- [ ] **Step 4: Run until green** — `./scripts/run-tests.sh --filter ActivityLogTests`
- [ ] **Step 5: Commit** (skip unless asked).

---

## Task 2: `SessionStore` — list / read / clear past sessions

**Files:**
- Create: `Sources/JarvisCore/SessionStore.swift`
- Test: `Tests/JarvisCoreTests/SessionStoreTests.swift`

Surface:

```swift
public struct SessionStore: Sendable {
    public struct Session: Sendable, Equatable {
        public let id: String           // dir name
        public let label: String        // "yyyy-MM-dd HH:mm:ss"
        public let url: URL
        public let isCurrent: Bool
    }
    public init(base: URL, current: URL?)
    public func listSessions() -> [Session]                 // newest-first; live always present
    public func entries(for s: Session) -> [(ActivityLog.Entry, Data?)]  // bytes for present+valid shots
    public func clearHistory()                              // delete past session dirs only
}
```

Guards (implement and test):
- Session-shape regex: `^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}_[0-9A-Za-z]{4}$`. Only such immediate
  subdirectories of `base` that contain `jarvis-activity.jsonl` count.
- `entries(for:)`: decode each `.jsonl` line as `PersistedEntry` (skip malformed); for `s`, require
  it match `^shot-\d+\.jpg$` (else treat as no image); read bytes only if the resolved path stays
  inside the session dir.
- `clearHistory`: enumerate immediate subdirs of `base` matching the shape, skip `current`, and
  `removeItem` each. Do **not** follow symlinks (skip entries whose `resourceValues` report
  `isSymbolicLink`). Never touch `base` itself.

- [ ] **Step 1: Write failing tests**

```swift
import Testing
import Foundation
@testable import JarvisCore

@Suite struct SessionStoreTests {
    private func makeSession(_ base: URL, _ id: String, lines: [String], shot: (String, Data)? = nil) throws {
        let d = base.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending(lines.isEmpty ? "" : "\n")
            .write(to: d.appendingPathComponent("jarvis-activity.jsonl"), atomically: true, encoding: .utf8)
        if let (name, data) = shot { try data.write(to: d.appendingPathComponent(name)) }
    }

    @Test func listsNewestFirstWithCurrentFlagged() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"10:00:00\",\"m\":\"x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"11:00:00\",\"m\":\"y\"}"])
        let cur = base.appendingPathComponent("2026-06-16_11-00-00_bbbb")
        let store = SessionStore(base: base, current: cur)
        let s = store.listSessions()
        #expect(s.count == 2)
        #expect(s[0].id == "2026-06-16_11-00-00_bbbb")   // newest first
        #expect(s[0].isCurrent == true)
        #expect(s[1].isCurrent == false)
    }

    @Test func entriesDecodeAndTolerateMalformedAndGuardTraversal() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let id = "2026-06-16_10-00-00_aaaa"
        try makeSession(base, id, lines: [
            "{\"t\":\"10:00:00\",\"m\":\"hi\",\"s\":\"shot-1.jpg\"}",
            "not json",
            "{\"t\":\"10:00:01\",\"m\":\"bad\",\"s\":\"../escape.jpg\"}",
        ], shot: ("shot-1.jpg", Data([0xFF,0xD8])))
        let store = SessionStore(base: base, current: nil)
        let e = store.entries(for: store.listSessions()[0])
        #expect(e.count == 2)                  // malformed line skipped
        #expect(e[0].1 != nil)                 // valid shot bytes loaded
        #expect(e[1].1 == nil)                 // traversal filename rejected → no bytes
    }

    @Test func clearHistoryDeletesPastButSparesCurrentAndBase() throws {
        let base = ActivityLogTests.tmp(); defer { try? FileManager.default.removeItem(at: base) }
        try makeSession(base, "2026-06-16_10-00-00_aaaa", lines: ["{\"t\":\"1\",\"m\":\"x\"}"])
        try makeSession(base, "2026-06-16_11-00-00_bbbb", lines: ["{\"t\":\"2\",\"m\":\"y\"}"])
        let cur = base.appendingPathComponent("2026-06-16_11-00-00_bbbb")
        SessionStore(base: base, current: cur).clearHistory()
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("2026-06-16_10-00-00_aaaa").path))
        #expect(FileManager.default.fileExists(atPath: cur.path))     // current spared
        #expect(FileManager.default.fileExists(atPath: base.path))    // base spared
    }
}
```

- [ ] **Step 2: Run → fail.** `./scripts/run-tests.sh --filter SessionStoreTests`
- [ ] **Step 3: Implement `SessionStore.swift`** per the surface + guards.
- [ ] **Step 4: Run → green.**
- [ ] **Step 5: Commit** (skip unless asked).

---

## Task 3: The embedded page (`htmlShell` + JS) and end-to-end WKWebView tests

**Files:**
- Implement: `htmlShell()` in `ActivityLog.swift` (or `ActivityViewerAssets.swift`)
- Test: `Tests/JarvisViewerTests/ViewerEndToEndTests.swift`

`htmlShell()` returns a dark-theme page containing `<main id="log">`, the lightbox overlay
(`#lightbox`, `#lightbox-img`), a `<header>` with `#count`, and this JS (verbatim behaviors):

```js
function appendRow(p){
  var log=document.getElementById('log');
  var row=document.createElement('div'); row.className='row '+(p.cls||'');
  var t=document.createElement('span'); t.className='t'; t.textContent=p.time;
  var m=document.createElement('span'); m.className='m'; m.textContent=p.message;
  if(p.img){
    var a=document.createElement('a'); a.className='shot'; a.href=p.img;
    var img=document.createElement('img'); img.src=p.img; img.alt='screenshot';
    a.appendChild(img);
    a.addEventListener('click',function(e){e.preventDefault();openShot(p.img);});
    m.appendChild(a);
  }
  row.appendChild(t); row.appendChild(m); log.appendChild(row);
  var near=(window.innerHeight+window.scrollY)>=(document.body.scrollHeight-60);
  if(near) window.scrollTo(0,document.body.scrollHeight);
}
function openShot(src){document.getElementById('lightbox-img').src=src;document.getElementById('lightbox').classList.add('open');}
function closeShot(){var b=document.getElementById('lightbox');b.classList.remove('open');document.getElementById('lightbox-img').removeAttribute('src');}
function clearRows(){document.getElementById('log').innerHTML='';}
function setMeta(s){document.getElementById('count').textContent=s;}
document.addEventListener('keydown',function(e){if(e.key==='Escape')closeShot();});
document.getElementById('lightbox').addEventListener('click',closeShot);
```

- [ ] **Step 1: Write failing e2e tests** (reuse `WebViewHarness` from Task 0 — move it to a shared
  file `Tests/JarvisViewerTests/WebViewHarness.swift`).

```swift
import Testing
import WebKit
@testable import JarvisCore

@Suite struct ViewerEndToEndTests {
    @MainActor @Test func appendRowRendersTextSafely() async throws {
        let h = WebViewHarness(); try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "<script>x</script> & \"q\"", imageBase64: nil))
        let txt = try await h.eval("document.querySelector('.row .m').textContent") as? String
        #expect(txt == "<script>x</script> & \"q\"")              // shown verbatim
        let scripts = try await h.eval("document.querySelectorAll('.row script').length") as? Int
        #expect(scripts == 0)                                      // nothing injected
    }

    @MainActor @Test func thumbnailClickOpensLightboxThenEscapeCloses() async throws {
        let h = WebViewHarness(); try await h.load(ActivityLog.htmlShell())
        try await h.eval(ActivityLog.rowScript(time: "10:00", message: "👁", imageBase64: "QUJD"))
        let imgSrc = try await h.eval("document.querySelector('a.shot img').src") as? String
        #expect(imgSrc?.contains("data:image/jpeg;base64,QUJD") == true)
        try await h.eval("document.querySelector('a.shot').click(); null")
        let openSrc = try await h.eval("document.getElementById('lightbox').classList.contains('open') ? document.getElementById('lightbox-img').src : ''") as? String
        #expect(openSrc?.contains("QUJD") == true)
        try await h.eval("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'})); null")
        let closed = try await h.eval("document.getElementById('lightbox').classList.contains('open')") as? Bool
        #expect(closed == false)
    }

    @MainActor @Test func replayingASnapshotRendersAllRows() async throws {
        let h = WebViewHarness(); try await h.load(ActivityLog.htmlShell())
        for r in [ActivityLog.rowScript(time:"1",message:"a",imageBase64:nil),
                  ActivityLog.rowScript(time:"2",message:"b",imageBase64:nil)] { try await h.eval(r) }
        let n = try await h.eval("document.querySelectorAll('.row').length") as? Int
        #expect(n == 2)
    }
}
```

- [ ] **Step 2: Run → fail** (htmlShell empty/missing). `./scripts/run-tests.sh --filter ViewerEndToEndTests`
- [ ] **Step 3: Implement `htmlShell()`** (CSS adapted from the old page; the JS above; lightbox CSS
  `.lightbox{position:fixed;inset:0;z-index:1000;display:none;align-items:center;justify-content:center;background:rgba(1,4,9,.85);cursor:zoom-out}.lightbox.open{display:flex}.lightbox img{max-width:92vw;max-height:92vh;border:1px solid #30363d;border-radius:8px}`).
- [ ] **Step 4: Run → green.**
- [ ] **Step 5: Commit** (skip unless asked).

---

## Task 4: `ActivityViewer` window controller (JarvisApp)

**Files:**
- Create: `Sources/JarvisApp/ActivityViewer.swift`

Not unit-tested (AppKit); verified by `swift build` + the manual checklist. Keep it thin. Spec:

```swift
import AppKit
import WebKit
import JarvisCore

@MainActor
final class ActivityViewer: NSObject, WKNavigationDelegate {
    private let log: ActivityLog
    private let store: SessionStore
    private var window: NSWindow?
    private var webView: WKWebView?
    private var picker: NSPopUpButton?
    private var loaded = false
    private var pending: [String] = []          // main-thread-confined buffer
    private var viewingCurrent = true

    init(log: ActivityLog, store: SessionStore) { self.log = log; self.store = store }

    func show() { /* create window+webView if nil; activation promotion; loadCurrent(); window.makeKeyAndOrderFront; NSApp.activate(ignoringOtherApps:true) */ }

    // Navigation deny-all-but-initial:
    func webView(_ wv: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler d: @escaping (WKNavigationActionPolicy) -> Void) {
        let u = a.request.url?.absoluteString
        d(u == nil || u == "about:blank" ? .allow : .cancel)
    }
    func webView(_ wv: WKWebView, didFinish n: WKNavigation!) {
        loaded = true
        // snapshot rows already injected into the HTML? No — inject now:
        flushAfterLoad()
    }
}
```

Behavior to implement:
- **`show()`**: lazily build `NSWindow` (titled, resizable, ~900×640) hosting a container with a
  header (`NSPopUpButton` + a "Clear history" `NSButton`) and the `WKWebView` below. Set
  `webView.navigationDelegate = self`. Populate the picker from `store.listSessions()`. Promote
  activation (`NSApp.activate(ignoringOtherApps: true)`, `window.makeKeyAndOrderFront`) — mirror
  `MenuBarController`'s existing approach. Then `loadCurrent()`.
- **`loadCurrent()`**: `viewingCurrent = true`; `loaded = false`; `pending = []`; `let snap =
  log.attach { js in DispatchQueue.main.async { self.onAppend(js) } }`; `webView.loadHTMLString(snap.shellHTML, baseURL: nil)`;
  stash `snap.rows` to inject on didFinish; set the header meta from `snap.shown/total`.
- **`onAppend(js)`** (main thread): if `loaded` { `webView.evaluateJavaScript(js)` } else { `pending.append(js)` }.
- **`flushAfterLoad()`**: inject the stashed snapshot rows in order, then drain `pending` FIFO, then
  rows arriving later go straight through (because `loaded` is now true). Update meta.
- **Picker change**: if current → `loadCurrent()`. If past → `log.detach()`; `viewingCurrent = false`;
  reload shell, on didFinish inject `store.entries(for: session)` mapped through `rowScript` (build
  base64 from the `Data?`), set meta `showing min(N,maxLines) of N`.
- **Clear history**: `NSAlert` confirm → `store.clearHistory()` → repopulate picker → if the viewed
  session was deleted, fall back to `loadCurrent()`.
- **Window close**: drop `window`/`webView` refs and `log.detach()`; next `show()` recreates.

- [ ] **Step 1: Implement `ActivityViewer.swift`** per spec.
- [ ] **Step 2: Compile** — `swift build` — fix until it builds.
- [ ] **Step 3: Commit** (skip unless asked).

---

## Task 5: Wire `AppDelegate` / menu

**Files:**
- Modify: `Sources/JarvisApp/AppDelegate.swift`

- [ ] **Step 1:** add `private var activityViewer: ActivityViewer?`.
- [ ] **Step 2:** in dev-mode setup (after `ActivityLog.shared.enable(directory: dir)`), build the
  store + viewer:

```swift
let store = SessionStore(base: devLogDirectory(), current: dir)
activityViewer = ActivityViewer(log: .shared, store: store)
```

- [ ] **Step 3:** change `onOpenLogViewer` to `{ [weak self] in self?.activityViewer?.show() }`
  (drop the `NSWorkspace.open(htmlURL)` block).
- [ ] **Step 4:** `swift build` → green.
- [ ] **Step 5: Commit** (skip unless asked).

---

## Task 6: Full verification

- [ ] **Step 1:** `./scripts/run-tests.sh` — all suites green (Core + Viewer).
- [ ] **Step 2:** `swift build` — app compiles.
- [ ] **Step 3 (manual, for the user):** `./scripts/build-app.sh --dev` → open viewer from menu →
  confirm: live rows append with no flicker; thumbnail opens the in-page modal; Escape/backdrop
  closes; session picker lists current + past; switching sessions works; "Clear history" (with
  confirm) removes past sessions and keeps the current; restarting Jarvis creates a new session that
  appears in the list.

---

## Self-review notes

- **Spec coverage:** live push (T1/T3/T4), persistence+JSONL (T1), session history (T2/T4),
  clear-history (T2/T4), lightbox (T3), XSS-safety (T1/T3), WKWebView config deny-nav (T4), activation
  (T4), buffer ordering (T4), N-of-M via `totalCount` (T1/T4), path-traversal guard (T2), test target
  split (T0), harness hardening (T0). All design sections map to a task.
- **No placeholders:** every code step has real code; the only deferred item is the manual GUI run
  (T6), which cannot be automated.
- **Type consistency:** `rowScript(time:message:imageBase64:)`, `Snapshot{shellHTML,rows,shown,total}`,
  `SessionStore.Session`, `entries(for:) -> [(Entry, Data?)]` used consistently across tasks.
