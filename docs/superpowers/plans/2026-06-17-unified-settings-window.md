# Unified Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add overlay text-size and background-opacity controls and consolidate the API-key dialog, the dev-mode activity log, and the new overlay controls into a single tabbed Settings window opened from one menu item.

**Architecture:** A `SettingsSection` protocol is the decoupling seam; a thin `SettingsWindow` hosts `[SettingsSection]` as `NSTabView` tabs and owns only window lifecycle (the accessory→regular activation-policy switch). Each panel (`APIKeySection`, `OverlaySection`, `ActivitySection`) is an independent unit. Persisted appearance lives in a Foundation-only `OverlayAppearance` store in `JarvisCore`, applied to the overlay through an `OverlayAppearanceApplying` protocol so panels never depend on AppKit `OverlayPanel` directly.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM (no Xcode project), AppKit, swift-testing (`@Suite`/`@Test`/`#expect`). Build: `swift build`. Tests: `./scripts/run-tests.sh`.

---

## Conventions for every task

- **Worktree paths only.** All paths are relative to the worktree root (`.claude/worktrees/rippling-marinating-duckling`). Never edit the main-repo copy.
- **Build green after every task.** Tasks are ordered so `swift build` succeeds at each commit. Additive-then-remove is used for the activity-viewer refactor (Task 7 adds, Task 9 removes the dead path) to keep builds green throughout.
- **Run a single swift-testing test** with `--filter`, e.g. `./scripts/run-tests.sh --filter OverlayAppearanceTests`.
- **SPM globs each target's whole tree** — new files under `Sources/<Target>/<Subfolder>/` need no `Package.swift` edit.

## File structure

| File | Status | Responsibility |
|------|--------|----------------|
| `Sources/JarvisCore/Config/Config.swift` | modify | Add overlay-appearance default + range static constants. |
| `Sources/JarvisCore/Overlay/OverlayAppearance.swift` | create | `UserDefaults`-backed `fontSize`/`backgroundOpacity` store (clamps, defaults from `Config`) + `OverlayAppearanceApplying` protocol. |
| `Sources/JarvisOverlay/OverlayPanel.swift` | modify | `setFontSize`/`setBackgroundOpacity`/`showAppearancePreview` + conformance + test hooks. |
| `Sources/JarvisApp/Settings/SettingsSection.swift` | create | Protocol: tab title + content view + close hook. |
| `Sources/JarvisApp/Settings/SettingsWindow.swift` | create | One window + `NSTabView`; owns activation-policy switch. |
| `Sources/JarvisApp/Settings/APIKeySection.swift` | create | Secure-field key entry (logic moved out of `MenuBarController`). |
| `Sources/JarvisApp/Settings/OverlaySection.swift` | create | Text-size + opacity sliders, live preview. |
| `Sources/JarvisApp/Settings/ActivitySection.swift` | create | Dev-only; wraps `ActivityViewer`'s vended content view. |
| `Sources/JarvisApp/Viewer/ActivityViewer.swift` | modify | Vend a content `NSView` (`makeContentView`/`teardown`); drop window ownership. |
| `Sources/JarvisApp/MenuBar/MenuBarController.swift` | modify | Replace key + log-viewer items with one "Settings…" item. |
| `Sources/JarvisApp/App/AppDelegate.swift` | modify | Build sections, create `SettingsWindow`, load+apply appearance at launch. |
| `Tests/JarvisCoreTests/Config/ConfigTests.swift` | modify | Assert the new appearance constants. |
| `Tests/JarvisCoreTests/Overlay/OverlayAppearanceTests.swift` | create | Persistence round-trip, clamping, defaults. |
| `Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift` | modify | Setter effects + `.none` survives a setter. |

---

## Task 1: Overlay-appearance defaults in Config

**Files:**
- Modify: `Sources/JarvisCore/Config/Config.swift`
- Test: `Tests/JarvisCoreTests/Config/ConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test to the `ConfigTests` suite in `Tests/JarvisCoreTests/Config/ConfigTests.swift` (after the existing `defaults()` test):

```swift
    @Test func overlayAppearanceConstants() {
        #expect(Config.overlayFontSizeDefault == 18)
        #expect(Config.overlayFontSizeRange == 12...32)
        #expect(Config.overlayOpacityDefault == 0.78)
        #expect(Config.overlayOpacityRange == 0.40...1.0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/run-tests.sh --filter ConfigTests`
Expected: build FAILS — `type 'Config' has no member 'overlayFontSizeDefault'`.

- [ ] **Step 3: Add the constants**

In `Sources/JarvisCore/Config/Config.swift`, add these static constants inside `struct Config`, immediately above the existing `public static let default = Config()` line:

```swift
    // Overlay appearance: defaults + allowed ranges. The persisted values live in UserDefaults via
    // OverlayAppearance; these are the single source of the defaults and the clamp bounds.
    public static let overlayFontSizeRange: ClosedRange<Double> = 12...32
    public static let overlayFontSizeDefault: Double = 18
    public static let overlayOpacityRange: ClosedRange<Double> = 0.40...1.0
    public static let overlayOpacityDefault: Double = 0.78
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/run-tests.sh --filter ConfigTests`
Expected: PASS (`overlayAppearanceConstants` and `defaults` both green).

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/Config/Config.swift Tests/JarvisCoreTests/Config/ConfigTests.swift
git commit -m "Add overlay-appearance defaults and ranges to Config"
```

---

## Task 2: OverlayAppearance store + applying protocol

**Files:**
- Create: `Sources/JarvisCore/Overlay/OverlayAppearance.swift`
- Test: `Tests/JarvisCoreTests/Overlay/OverlayAppearanceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/JarvisCoreTests/Overlay/OverlayAppearanceTests.swift`:

```swift
import Testing
import Foundation
@testable import JarvisCore

@Suite struct OverlayAppearanceTests {
    /// A fresh, isolated UserDefaults suite per test so nothing touches the real app domain.
    private func freshDefaults() -> UserDefaults {
        let suite = "OverlayAppearanceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsWhenUnset() {
        let a = OverlayAppearance(defaults: freshDefaults())
        #expect(a.fontSize == Config.overlayFontSizeDefault)
        #expect(a.backgroundOpacity == Config.overlayOpacityDefault)
    }

    @Test func roundTripsThroughDefaults() {
        let d = freshDefaults()
        OverlayAppearance(defaults: d).fontSize = 22
        OverlayAppearance(defaults: d).backgroundOpacity = 0.9
        let reloaded = OverlayAppearance(defaults: d)
        #expect(reloaded.fontSize == 22)
        #expect(reloaded.backgroundOpacity == 0.9)
    }

    @Test func clampsOutOfRange() {
        let a = OverlayAppearance(defaults: freshDefaults())
        a.fontSize = 999
        a.backgroundOpacity = 999
        #expect(a.fontSize == Config.overlayFontSizeRange.upperBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.upperBound)

        a.fontSize = 1
        a.backgroundOpacity = 0
        #expect(a.fontSize == Config.overlayFontSizeRange.lowerBound)
        #expect(a.backgroundOpacity == Config.overlayOpacityRange.lowerBound)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/run-tests.sh --filter OverlayAppearanceTests`
Expected: build FAILS — `cannot find 'OverlayAppearance' in scope`.

- [ ] **Step 3: Create the implementation**

Create `Sources/JarvisCore/Overlay/OverlayAppearance.swift`:

```swift
import Foundation

/// Persisted overlay appearance: font size (points) and background opacity (0–1). Backed by
/// UserDefaults; defaults and clamp bounds come from `Config`. Foundation-only so it stays
/// unit-testable in JarvisCore. Inject a `UserDefaults(suiteName:)` in tests.
public final class OverlayAppearance {
    private let defaults: UserDefaults

    private enum Key {
        static let fontSize = "overlay.fontSize"
        static let opacity = "overlay.backgroundOpacity"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var fontSize: Double {
        get {
            guard defaults.object(forKey: Key.fontSize) != nil else { return Config.overlayFontSizeDefault }
            return Self.clamp(defaults.double(forKey: Key.fontSize), to: Config.overlayFontSizeRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayFontSizeRange), forKey: Key.fontSize) }
    }

    public var backgroundOpacity: Double {
        get {
            guard defaults.object(forKey: Key.opacity) != nil else { return Config.overlayOpacityDefault }
            return Self.clamp(defaults.double(forKey: Key.opacity), to: Config.overlayOpacityRange)
        }
        set { defaults.set(Self.clamp(newValue, to: Config.overlayOpacityRange), forKey: Key.opacity) }
    }

    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

/// How a settings panel pushes live appearance changes to the overlay without depending on AppKit.
/// The real `OverlayPanel` (in JarvisApp's overlay target) conforms; tests can supply a fake.
@MainActor
public protocol OverlayAppearanceApplying: AnyObject {
    func setFontSize(_ points: Double)
    func setBackgroundOpacity(_ opacity: Double)
    /// Show a sample tip (on) or clear it (off) so size/opacity changes are visible while the
    /// settings window is open. Must preserve screen-capture exclusion.
    func showAppearancePreview(_ on: Bool)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/run-tests.sh --filter OverlayAppearanceTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisCore/Overlay/OverlayAppearance.swift Tests/JarvisCoreTests/Overlay/OverlayAppearanceTests.swift
git commit -m "Add OverlayAppearance store and OverlayAppearanceApplying protocol"
```

---

## Task 3: OverlayPanel setters, live preview, and conformance

**Files:**
- Modify: `Sources/JarvisOverlay/OverlayPanel.swift`
- Test: `Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these two synchronous main-actor tests to the `OverlayInvisibilityTests` suite in `Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift` (after `overlaySetsCaptureExclusionAtInit`):

```swift
    @MainActor @Test
    func settersChangeFontAndOpacity() {
        let overlay = OverlayPanel()
        overlay.setFontSize(26)
        overlay.setBackgroundOpacity(0.5)
        #expect(overlay.currentFontPointSize == 26)
        #expect(abs(overlay.currentBackgroundAlpha - 0.5) < 0.001)
    }

    @MainActor @Test
    func previewKeepsCaptureExclusion() {
        let overlay = OverlayPanel()
        overlay.showAppearancePreview(true)
        #expect(overlay.currentSharingType == .none)
        overlay.showAppearancePreview(false)
        #expect(overlay.currentSharingType == .none)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/run-tests.sh --filter OverlayInvisibilityTests`
Expected: build FAILS — `value of type 'OverlayPanel' has no member 'setFontSize'`.

- [ ] **Step 3: Add conformance to the class declaration**

In `Sources/JarvisOverlay/OverlayPanel.swift`, change the class declaration line:

```swift
public final class OverlayPanel: NSObject, OverlayRendering {
```

to:

```swift
public final class OverlayPanel: NSObject, OverlayRendering, OverlayAppearanceApplying {
```

- [ ] **Step 4: Add the setters, preview, and test hooks**

In `Sources/JarvisOverlay/OverlayPanel.swift`, insert this block immediately after the `hide()` method (`private func hide() { panel.orderOut(nil) }`) and before the `// MARK: - Test hooks` comment:

```swift
    // MARK: - OverlayAppearanceApplying

    /// Live preview sample shown while the Settings window is open.
    private static let previewText = "Sample overlay text"

    public func setFontSize(_ points: Double) {
        label.font = .systemFont(ofSize: CGFloat(points), weight: .medium)
    }

    public func setBackgroundOpacity(_ opacity: Double) {
        panel.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity))
    }

    /// Show a sample tip (on) or clear it (off). Cancels any pending auto-hide so a live coaching
    /// tip doesn't yank the preview away mid-adjust, and re-asserts capture exclusion (same
    /// defense-in-depth as `show()`; an activation-policy flip can drop `sharingType`).
    public func showAppearancePreview(_ on: Bool) {
        if on {
            hideWorkItem?.cancel()
            panel.sharingType = .none
            label.stringValue = Self.previewText
            panel.orderFrontRegardless()
        } else {
            hide()
        }
    }
```

Then add these two test hooks inside the existing `// MARK: - Test hooks` section, right after the `currentSharingType` hook:

```swift
    /// The label's current font point size.
    var currentFontPointSize: CGFloat { label.font?.pointSize ?? 0 }

    /// The panel background's current alpha (the opacity the user picked).
    var currentBackgroundAlpha: CGFloat { panel.backgroundColor.alphaComponent }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/run-tests.sh --filter OverlayInvisibilityTests`
Expected: PASS (new tests plus the existing `overlaySetsCaptureExclusionAtInit` and `overlayReassertsExclusionWhenShown`).

- [ ] **Step 6: Commit**

```bash
git add Sources/JarvisOverlay/OverlayPanel.swift Tests/JarvisOverlayTests/OverlayInvisibilityTests.swift
git commit -m "Add OverlayPanel appearance setters and live preview"
```

---

## Task 4: SettingsSection protocol + SettingsWindow host

**Files:**
- Create: `Sources/JarvisApp/Settings/SettingsSection.swift`
- Create: `Sources/JarvisApp/Settings/SettingsWindow.swift`

No unit test — AppKit window UI is verified by the live run in Task 8. The check here is a clean `swift build`.

- [ ] **Step 1: Create the protocol**

Create `Sources/JarvisApp/Settings/SettingsSection.swift`:

```swift
import AppKit

/// One panel in the unified Settings window. Each section is self-contained: it knows its tab
/// title, builds its own content view, and cleans up when the window closes.
@MainActor
protocol SettingsSection: AnyObject {
    var title: String { get }
    func makeView() -> NSView
    /// Called when the Settings window closes. Default: no-op.
    func windowWillClose()
}

extension SettingsSection {
    func windowWillClose() {}
}
```

- [ ] **Step 2: Create the window host**

Create `Sources/JarvisApp/Settings/SettingsWindow.swift`:

```swift
import AppKit

/// One window hosting all settings sections as tabs. Non-modal: it promotes the accessory app to
/// `.regular` while open (so secure/text fields can become first responder and accept paste) and
/// drops back to `.accessory` on close — the lesson the old API-key dialog and activity viewer
/// both learned. The window is rebuilt on each open so sections start fresh (mirrors the viewer's
/// rebuild-on-show pattern).
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let sections: [SettingsSection]
    private var window: NSWindow?

    init(sections: [SettingsSection]) {
        self.sections = sections
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        build()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Jarvis Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let tabView = NSTabView(frame: win.contentView!.bounds)
        tabView.autoresizingMask = [.width, .height]
        for section in sections {
            let item = NSTabViewItem(identifier: section.title)
            item.label = section.title
            item.view = section.makeView()
            tabView.addTabViewItem(item)
        }
        win.contentView!.addSubview(tabView)
        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        for section in sections { section.windowWillClose() }
        NSApp.setActivationPolicy(.accessory)   // back to menu-bar-only
        window = nil
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (no references yet; just compiles.)

- [ ] **Step 4: Commit**

```bash
git add Sources/JarvisApp/Settings/SettingsSection.swift Sources/JarvisApp/Settings/SettingsWindow.swift
git commit -m "Add SettingsSection protocol and SettingsWindow host"
```

---

## Task 5: APIKeySection

**Files:**
- Create: `Sources/JarvisApp/Settings/APIKeySection.swift`

Logic mirrors the old `MenuBarController.setKey` (which Task 8 removes), but non-modal: the host window is already `.regular`, so the secure field can become first responder without `runModal`.

- [ ] **Step 1: Create the section**

Create `Sources/JarvisApp/Settings/APIKeySection.swift`:

```swift
import AppKit
import JarvisCore

/// Settings panel for the OpenAI API key. Saves to the Keychain and reports back via `onKeySaved`
/// (the app restarts the pipeline only if it was already running). Replaces the old modal dialog in
/// MenuBarController.
@MainActor
final class APIKeySection: NSObject, SettingsSection {
    let title = "API Key"

    private let keychain: KeychainSecretStore
    private let onKeySaved: (String) -> Void
    private var field: NSSecureTextField?
    private var status: NSTextField?

    init(keychain: KeychainSecretStore, onKeySaved: @escaping (String) -> Void) {
        self.keychain = keychain
        self.onKeySaved = onKeySaved
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let label = NSTextField(labelWithString: "Paste your OpenAI API key. It’s stored in your Keychain.")
        label.frame = NSRect(x: 24, y: 360, width: 512, height: 20)
        view.addSubview(label)

        let field = NSSecureTextField(frame: NSRect(x: 24, y: 322, width: 512, height: 26))
        field.placeholderString = "sk-…"
        view.addSubview(field)
        self.field = field

        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.frame = NSRect(x: 444, y: 282, width: 92, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        view.addSubview(save)

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 24, y: 288, width: 400, height: 20)
        status.textColor = .secondaryLabelColor
        view.addSubview(status)
        self.status = status

        return view
    }

    @objc private func saveTapped() {
        let token = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { status?.stringValue = "Enter a key first."; return }
        keychain.setApiKey(token)
        onKeySaved(token)
        status?.stringValue = "Key saved ✓"
        field?.stringValue = ""
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/JarvisApp/Settings/APIKeySection.swift
git commit -m "Add APIKeySection settings panel"
```

---

## Task 6: OverlaySection

**Files:**
- Create: `Sources/JarvisApp/Settings/OverlaySection.swift`

- [ ] **Step 1: Create the section**

Create `Sources/JarvisApp/Settings/OverlaySection.swift`:

```swift
import AppKit
import JarvisCore

/// Settings panel for overlay appearance: Text Size and Background Opacity sliders with live
/// numeric readouts. Persists through `OverlayAppearance` and pushes live changes to the overlay via
/// `OverlayAppearanceApplying` (no direct OverlayPanel dependency). Shows a sample overlay while the
/// window is open so changes are visible, and clears it on close.
@MainActor
final class OverlaySection: NSObject, SettingsSection {
    let title = "Overlay"

    private let appearance: OverlayAppearance
    private let applying: OverlayAppearanceApplying
    private var sizeReadout: NSTextField?
    private var opacityReadout: NSTextField?

    init(appearance: OverlayAppearance, applying: OverlayAppearanceApplying) {
        self.appearance = appearance
        self.applying = applying
    }

    func makeView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 432))

        let sizeLabel = NSTextField(labelWithString: "Text Size")
        sizeLabel.frame = NSRect(x: 24, y: 372, width: 200, height: 20)
        view.addSubview(sizeLabel)

        let sizeSlider = NSSlider(value: appearance.fontSize,
                                  minValue: Config.overlayFontSizeRange.lowerBound,
                                  maxValue: Config.overlayFontSizeRange.upperBound,
                                  target: self, action: #selector(sizeChanged))
        sizeSlider.frame = NSRect(x: 24, y: 342, width: 440, height: 24)
        view.addSubview(sizeSlider)

        let sizeReadout = NSTextField(labelWithString: "")
        sizeReadout.frame = NSRect(x: 472, y: 344, width: 64, height: 20)
        view.addSubview(sizeReadout)
        self.sizeReadout = sizeReadout

        let opacityLabel = NSTextField(labelWithString: "Background Opacity")
        opacityLabel.frame = NSRect(x: 24, y: 292, width: 200, height: 20)
        view.addSubview(opacityLabel)

        let opacitySlider = NSSlider(value: appearance.backgroundOpacity,
                                     minValue: Config.overlayOpacityRange.lowerBound,
                                     maxValue: Config.overlayOpacityRange.upperBound,
                                     target: self, action: #selector(opacityChanged))
        opacitySlider.frame = NSRect(x: 24, y: 262, width: 440, height: 24)
        view.addSubview(opacitySlider)

        let opacityReadout = NSTextField(labelWithString: "")
        opacityReadout.frame = NSRect(x: 472, y: 264, width: 64, height: 20)
        view.addSubview(opacityReadout)
        self.opacityReadout = opacityReadout

        updateReadouts()
        applying.showAppearancePreview(true)   // live preview while the window is open
        return view
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        appearance.fontSize = sender.doubleValue
        applying.setFontSize(appearance.fontSize)
        updateReadouts()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        appearance.backgroundOpacity = sender.doubleValue
        applying.setBackgroundOpacity(appearance.backgroundOpacity)
        updateReadouts()
    }

    private func updateReadouts() {
        sizeReadout?.stringValue = "\(Int(appearance.fontSize)) pt"
        opacityReadout?.stringValue = "\(Int(appearance.backgroundOpacity * 100))%"
    }

    func windowWillClose() {
        applying.showAppearancePreview(false)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/JarvisApp/Settings/OverlaySection.swift
git commit -m "Add OverlaySection settings panel with live preview"
```

---

## Task 7: Activity viewer vends a content view + ActivitySection

This is **additive** — `makeContentView()`/`teardown()` are added but `show()`/`window` stay, so the build and the existing `viewer.show()` call in `AppDelegate` keep working. The dead window path is removed in Task 9.

**Files:**
- Modify: `Sources/JarvisApp/Viewer/ActivityViewer.swift`
- Create: `Sources/JarvisApp/Settings/ActivitySection.swift`

- [ ] **Step 1: Add `makeContentView()` and `teardown()` to ActivityViewer**

In `Sources/JarvisApp/Viewer/ActivityViewer.swift`, insert this block immediately after the existing `// MARK: - Build` comment and its `build()` method (i.e. right before `// MARK: - Session list`):

```swift
    // MARK: - Embeddable content view (unified Settings window)

    /// Build the viewer's content (header + WKWebView) as a standalone view for embedding in the
    /// Settings window's Activity tab. Starts live updates and loads the current session. The host
    /// window owns lifecycle; call `teardown()` when it closes. Reuses all the loading/session logic
    /// below unchanged.
    func makeContentView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 596))
        content.autoresizingMask = [.width, .height]

        let header = NSVisualEffectView(frame: NSRect(x: 0, y: content.bounds.height - 44, width: content.bounds.width, height: 44))
        header.autoresizingMask = [.width, .minYMargin]
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active

        let sessionLabel = NSTextField(labelWithString: "Session")
        sessionLabel.frame = NSRect(x: 14, y: 13, width: 60, height: 18)
        sessionLabel.textColor = .secondaryLabelColor
        header.addSubview(sessionLabel)

        let pop = NSPopUpButton(frame: NSRect(x: 76, y: 8, width: 360, height: 26))
        pop.target = self
        pop.action = #selector(sessionChanged)
        pop.toolTip = "Switch between this and previous dev sessions"
        pop.autoresizingMask = [.maxXMargin]
        header.addSubview(pop)
        self.picker = pop

        let clear = NSButton(title: "Clear history", target: self, action: #selector(clearHistoryTapped))
        clear.bezelStyle = .rounded
        clear.toolTip = "Delete all previous sessions (keeps the current one)"
        clear.frame = NSRect(x: content.bounds.width - 146, y: 8, width: 132, height: 28)
        clear.autoresizingMask = [.minXMargin]
        header.addSubview(clear)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - 44))
        wv.autoresizingMask = [.width, .height]
        wv.navigationDelegate = self

        content.addSubview(wv)
        content.addSubview(header)
        self.webView = wv

        populatePicker()
        loadCurrent()
        return content
    }

    /// Stop receiving live rows and release the WebView. Called by the host when the window closes.
    func teardown() {
        log.detach()
        webView = nil
        loaded = false
        pending = []
        snapshotRows = []
    }
```

- [ ] **Step 2: Create ActivitySection**

Create `Sources/JarvisApp/Settings/ActivitySection.swift`:

```swift
import AppKit
import JarvisCore

/// Dev-mode-only settings panel that embeds the live activity viewer. Thin wrapper: the viewer owns
/// all WKWebView/session/live-append logic; this just vends its content view into a tab and tears it
/// down on close.
@MainActor
final class ActivitySection: NSObject, SettingsSection {
    let title = "Activity"

    private let viewer: ActivityViewer

    init(viewer: ActivityViewer) {
        self.viewer = viewer
    }

    func makeView() -> NSView { viewer.makeContentView() }
    func windowWillClose() { viewer.teardown() }
}
```

- [ ] **Step 3: Build and run existing viewer tests to confirm nothing regressed**

Run: `swift build && ./scripts/run-tests.sh --filter JarvisViewerTests`
Expected: `Build complete!` then the existing viewer tests PASS (logic untouched).

- [ ] **Step 4: Commit**

```bash
git add Sources/JarvisApp/Viewer/ActivityViewer.swift Sources/JarvisApp/Settings/ActivitySection.swift
git commit -m "Let ActivityViewer vend a content view; add ActivitySection"
```

---

## Task 8: Slim MenuBarController + wire the Settings window

These two files are API-coupled (the controller's callbacks are wired in `AppDelegate`), so they change together to keep the build green.

**Files:**
- Modify: `Sources/JarvisApp/MenuBar/MenuBarController.swift`
- Modify: `Sources/JarvisApp/App/AppDelegate.swift`

- [ ] **Step 1: Replace MenuBarController with the slimmed version**

Overwrite `Sources/JarvisApp/MenuBar/MenuBarController.swift` with:

```swift
import AppKit

/// Menu-bar status item: start/stop, a "Settings…" item, and a session interjection counter.
/// Exactly two states: ⚪️ stopped and 🟢 running. All settings (API key, overlay appearance, the
/// dev activity log) live in the unified Settings window, opened via `onOpenSettings`.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let counterItem = NSMenuItem(title: "Interjections: 0", action: nil, keyEquivalent: "")
    private let startStopItem = NSMenuItem(title: "Start Jarvis", action: nil, keyEquivalent: "s")
    private var interjections = 0
    /// Whether the listen/coach pipeline is currently running.
    private(set) var isRunning = false

    /// Fired when the user asks to start the pipeline. Returns `true` if it actually started.
    var onStart: (() -> Bool)?
    /// Fired when the user asks to stop the pipeline.
    var onStop: (() -> Void)?
    /// Fired when the user picks "Settings…". Opens the unified Settings window.
    var onOpenSettings: (() -> Void)?

    override init() {
        super.init()
        let menu = NSMenu()
        startStopItem.target = self
        startStopItem.action = #selector(toggleStartStop)
        menu.addItem(startStopItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(counterItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refreshUI()
    }

    func noteSpoke() {
        interjections += 1
        counterItem.title = "Interjections: \(interjections)"
    }

    /// Reset the per-session interjection count (called on each Start).
    func resetCounter() {
        interjections = 0
        counterItem.title = "Interjections: 0"
    }

    /// The single source of truth for running state.
    func setRunning(_ running: Bool) {
        isRunning = running
        refreshUI()
    }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func toggleStartStop() {
        if isRunning {
            onStop?()
            setRunning(false)
        } else {
            setRunning(onStart?() ?? false)
        }
    }

    /// Single source of truth for the status title and the start/stop label.
    private func refreshUI() {
        startStopItem.title = isRunning ? "Stop Jarvis" : "Start Jarvis"
        statusItem.button?.title = isRunning ? "🟢 Jarvis" : "⚪️ Jarvis"
    }
}
```

- [ ] **Step 2: Update AppDelegate — add stored properties**

In `Sources/JarvisApp/App/AppDelegate.swift`, add two stored properties. After the existing line `private var menuBar: MenuBarController!`, insert:

```swift
    private var settingsWindow: SettingsWindow!
    private let appearance = OverlayAppearance()
```

- [ ] **Step 3: Update AppDelegate — apply appearance and wire sections**

In `applicationDidFinishLaunching`, replace this existing block:

```swift
        overlay = OverlayPanel()
        menuBar = MenuBarController(keychain: keychain, showLogViewer: devMode)
        // Dev mode: open this session's activity in the in-app viewer window on demand.
        menuBar.onOpenLogViewer = { [weak self] in
            guard let viewer = self?.activityViewer else { jlog("Jarvis: no activity log to open yet."); return }
            viewer.show()
        }
        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }
        // A pasted key is stored but does not auto-start; restart only if already running, and
        // reflect the real outcome back into the menu state.
        menuBar.onKeySaved = { [weak self] _ in
            guard let self, self.transcriber != nil else { return }
            self.menuBar.setRunning(self.start())
        }
```

with:

```swift
        overlay = OverlayPanel()
        overlay.setFontSize(appearance.fontSize)
        overlay.setBackgroundOpacity(appearance.backgroundOpacity)

        menuBar = MenuBarController()

        // Unified Settings window: API key + overlay appearance always; the dev activity log only
        // in dev mode. A pasted key is stored but does not auto-start; restart only if already
        // running, reflecting the real outcome back into the menu state.
        var sections: [SettingsSection] = [
            APIKeySection(keychain: keychain, onKeySaved: { [weak self] _ in
                guard let self, self.transcriber != nil else { return }
                self.menuBar.setRunning(self.start())
            }),
            OverlaySection(appearance: appearance, applying: overlay),
        ]
        if let viewer = activityViewer {
            sections.append(ActivitySection(viewer: viewer))
        }
        settingsWindow = SettingsWindow(sections: sections)
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        // The menu drives the pipeline lifecycle. Jarvis does NOT auto-start; the user presses Start.
        menuBar.onStart = { [weak self] in self?.start() ?? false }
        menuBar.onStop = { [weak self] in self?.stop() }
```

- [ ] **Step 4: Update the no-key warning text**

In `Sources/JarvisApp/App/AppDelegate.swift`, in `warnNoKey()`, change the `informativeText` line from:

```swift
        alert.informativeText = "Choose “Set OpenAI API Key…” from the Jarvis menu, then press Start."
```

to:

```swift
        alert.informativeText = "Open “Settings…” from the Jarvis menu, paste your key, then press Start."
```

- [ ] **Step 5: Build to verify the integration compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Manual run — verify the unified window**

Run: `./scripts/build-app.sh --dev --run`
Then in the menu bar:
1. Click **⚪️ Jarvis → Settings…** — a "Jarvis Settings" window opens with tabs **API Key**, **Overlay**, **Activity** (Activity present because `--dev`).
2. On **Overlay**, drag **Text Size** and **Background Opacity** — the sample overlay ("Sample overlay text") appears near the bottom of the screen and updates live.
3. Close the window — the sample overlay disappears.
4. Reopen Settings, go to **API Key** — the field accepts typing/paste (non-modal focus works).
5. Quit Jarvis (menu → Quit). Relaunch with `./scripts/build-app.sh --dev --run`, open Settings → Overlay — the sliders show the values you set (persistence works).

Expected: all five behave as described. If the Activity tab is empty, confirm you launched with `--dev`.

- [ ] **Step 7: Commit**

```bash
git add Sources/JarvisApp/MenuBar/MenuBarController.swift Sources/JarvisApp/App/AppDelegate.swift
git commit -m "Replace menu items with one Settings entry; wire the unified Settings window"
```

---

## Task 9: Remove dead window code from ActivityViewer + final verification + wiki

Now that nothing calls `ActivityViewer.show()`, remove the obsolete window-management path, run the full suite, and fold the design into the wiki.

**Files:**
- Modify: `Sources/JarvisApp/Viewer/ActivityViewer.swift`
- Modify: `wiki/activity-viewer.md`, `wiki/overlay-invisibility.md`, `wiki/status.md`, `wiki/index.md`
- Delete: `docs/superpowers/specs/2026-06-17-unified-settings-window-design.md` (build artifact; fold into wiki per `wiki/CLAUDE.md` rule 7)

- [ ] **Step 1: Remove the obsolete window path from ActivityViewer**

In `Sources/JarvisApp/Viewer/ActivityViewer.swift`:

1. Change the class declaration from:

```swift
final class ActivityViewer: NSObject, WKNavigationDelegate, NSWindowDelegate {
```

to:

```swift
final class ActivityViewer: NSObject, WKNavigationDelegate {
```

2. Delete the stored property line:

```swift
    private var window: NSWindow?
```

3. Delete the entire `show()` method (the doc-comment block plus the method, from `/// Open the viewer (creating it on first use)…` through the closing brace of `show()`).

4. Delete the entire `build()` method (the `// MARK: - Build` comment, its doc comment, and the method body that creates the `NSWindow`). `makeContentView()` (added in Task 7) replaces it.

5. Delete the entire `windowWillClose(_:)` method and the `// MARK: - NSWindowDelegate` comment that precedes only it (keep the `// MARK: - WKNavigationDelegate` section intact).

- [ ] **Step 2: Build and run the full test suite**

Run: `swift build && ./scripts/run-tests.sh`
Expected: `Build complete!` then all suites PASS — `JarvisCoreTests` (incl. `ConfigTests`, `OverlayAppearanceTests`), `JarvisOverlayTests` (incl. the new setter/preview tests), `JarvisViewerTests`.

- [ ] **Step 3: Manual smoke re-run**

Run: `./scripts/build-app.sh --dev --run`
Verify the Settings → Activity tab still shows live log rows (the viewer's content view works without its old window). Quit when done.

- [ ] **Step 4: Fold the design into the wiki and delete the build-time docs**

Per `wiki/CLAUDE.md` rule 7 (wiki holds final state; build-time plans/specs don't live there afterward):

1. In `wiki/activity-viewer.md`, update the opening description: the viewer is now embedded as the **Activity tab of the unified Settings window** (dev mode only), not a standalone window; it vends a content view via `makeContentView()` and is torn down via `teardown()` when the window closes.
2. In `wiki/overlay-invisibility.md`, note that `showAppearancePreview(_:)` and the appearance setters re-assert `sharingType = .none` (same defense-in-depth as `show()`), so the live preview stays capture-excluded.
3. Add a new short section (or page) describing the **Settings window**: one menu item → `SettingsWindow` hosting `[SettingsSection]` (`APIKeySection`, `OverlaySection`, dev-only `ActivitySection`); overlay text size + background opacity persisted via `OverlayAppearance` (UserDefaults; defaults/ranges in `Config`). Link it from `wiki/index.md`.
4. In `wiki/status.md`, add a one-line key-decision entry: unified Settings window replaces the separate API-key dialog and log-viewer menu item; overlay text size + opacity are now user-adjustable and persisted.
5. Delete the now-folded build artifacts:

```bash
git rm docs/superpowers/specs/2026-06-17-unified-settings-window-design.md
```

- [ ] **Step 5: Commit**

```bash
git add Sources/JarvisApp/Viewer/ActivityViewer.swift wiki/
git commit -m "Remove dead ActivityViewer window path; document Settings window in wiki"
```

---

## Self-review notes (already applied)

- **Spec coverage:** one menu item (Task 8); unified tabbed window (Task 4); API key (Task 5); overlay size + opacity sliders with live preview (Tasks 3, 6); dev-only activity tab (Task 7); `OverlayAppearance` persistence + clamping + `Config` defaults (Tasks 1, 2); `OverlayPanel` setters preserving `.none` (Task 3); `ActivityViewer` view-extraction with existing tests green (Tasks 7, 9). All covered.
- **Type consistency:** `OverlayAppearanceApplying` methods (`setFontSize`, `setBackgroundOpacity`, `showAppearancePreview`) are defined identically in Task 2 (protocol), Task 3 (conformance), and Task 6 (call sites). `OverlayAppearance.fontSize` / `.backgroundOpacity` and `Config.overlay*` constants match across Tasks 1, 2, 6. `SettingsSection` (`title` / `makeView()` / `windowWillClose()`) is consistent across Tasks 4–7.
- **Build-green ordering:** the ActivityViewer refactor is additive in Task 7 and only removes the dead path in Task 9, after Task 8 drops the last `show()` caller — so every commit compiles.
- **Known interaction (acceptable, YAGNI):** opening Settings shows the preview overlay even mid-session; closing hides it. Coordinating preview with a live coaching tip is out of scope.
