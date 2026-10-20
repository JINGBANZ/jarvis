#if JARVIS_LIVE_E2E
import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

@MainActor
final class SettingsHarnessAppDelegate: NSObject, NSApplicationDelegate, BrainCompositionHost {
    private let output: URL
    private let relaunch: Bool
    private var task: Task<Void, Never>?
    var liveCoachDriver: CoachDriver?
    var liveSessionDirectory: URL? { output }
    var liveSessionEvidence: FileSessionAudit? { nil }
    var isTranscriptionLive: Bool { true }

    init(arguments: [String] = CommandLine.arguments) throws {
        guard Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
              let index = arguments.firstIndex(of: "--settings-harness-output"),
              arguments.indices.contains(index + 1) else { throw CocoaError(.fileWriteNoPermission) }
        output = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let base = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(".jarvis/settings-harness")
        guard output.deletingLastPathComponent() == base,
              output.resolvingSymlinksInPath() == output,
              FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteNoPermission) }
        relaunch = arguments.contains("--settings-harness-relaunch")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited) // ghost-mode-allowed: explicit hidden Settings harness
        task = Task {
            var failure = ""
            do { try await run() } catch { failure = String(describing: error) }
            let result = ["status": failure.isEmpty ? "passed" : "failed", "failure": failure]
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                try data.write(to: output.appendingPathComponent(relaunch ? "relaunch.json" : "initial.json"))
            } catch { fputs("Settings harness: result write failed\n", stderr) }
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil) // ghost-mode-allowed: explicit Settings harness completion
                }
            }
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "SettingsHarness", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }

    private func run() async throws {
        let domain = "jarvis.settings-harness.\(output.lastPathComponent)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { if relaunch { defaults.removePersistentDomain(forName: domain) } }
        let preferences = BrainPreferences(defaults: defaults)
        try require(preferences.saveConversations == relaunch, "storage default or cross-process persistence")
        let hotkeys = CoachingShortcut.allCases.map { HotkeyPreferences(defaults: defaults, shortcut: $0) }
        let shortcuts = HotkeySection(preferences: hotkeys,
            mouseController: MouseHotkeyController(preferences: hotkeys),
            hasActiveHotkey: { _ in true }, applyCombination: { _, _ in .registered })
        let section = GeneralSection(preferences: preferences, shortcuts: shortcuts)
        try require(section.destination == .general, "General navigation")
        let page = section.makePage()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.excludeFromScreenCapture()
        let background = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        page.frame = background.bounds
        page.autoresizingMask = [.width, .height]
        background.addSubview(page)
        window.contentView = background
        section.didBecomeActive()
        defer { section.didResignActive(); section.windowWillClose(); window.orderOut(nil) }
        page.layoutSubtreeIfNeeded()
        let views = descendants(page)
        guard let privacy = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Privacy" }),
              let shortcutsTab = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Shortcuts" }),
              let toggle = views.compactMap({ $0 as? NSSwitch }).first else { throw CocoaError(.coderValueNotFound) }
        let rows = views.compactMap { $0 as? ShortcutSettingsRowView }
        try require(rows.count == 5 && rows.allSatisfy {
            descendants($0).compactMap { $0 as? NSTextField }.filter { !$0.stringValue.isEmpty }.count == 2
        }, "all shortcuts retain their name and description")
        try snapshot(background, name: "shortcuts")
        guard let recorder = views.compactMap({ $0 as? HotkeyRecorderButton }).first else {
            throw CocoaError(.coderValueNotFound)
        }
        recorder.performClick(nil)
        try require(recorder.title == "Press keys…", "keyboard recording starts")
        privacy.performClick(nil)
        try require(recorder.title != "Press keys…", "switching tabs cancels recording")
        try require(toggle.state == (relaunch ? .on : .off), "persisted switch value")
        try require(!views.compactMap({ $0 as? NSTextField }).contains {
            $0.stringValue.contains("Provider retention") || $0.stringValue.contains("Provider coverage")
        }, "concise privacy copy")
        try snapshot(background, name: "privacy")
        for size in [NSSize(width: 560, height: 460), NSSize(width: 820, height: 600)] {
            background.frame.size = size
            background.layoutSubtreeIfNeeded()
            for tab in [shortcutsTab, privacy] {
                tab.performClick(nil)
                background.layoutSubtreeIfNeeded()
                try require(rows.allSatisfy { row in
                    row.subviews.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= row.bounds.width + 1 }
                }, "shortcut controls fit at minimum and default sizes")
                try snapshot(background, name: "\(tab.title.lowercased())-\(Int(size.width))")
            }
        }
        background.appearance = NSAppearance(named: .darkAqua)
        for tab in [shortcutsTab, privacy] {
            tab.performClick(nil)
            try snapshot(background, name: "\(tab.title.lowercased())-dark")
        }
        if relaunch { return }
        let traffic = SettingsHarnessTraffic()
        let brain = BrainComposition(secrets: FileSecretStore(), host: self,
            supervisor: LocalProxySupervisor(executable: nil, home: output.appendingPathComponent("proxy")),
            preferences: preferences,
            send: { request in try await traffic.send(request) })
        brain.sessionWillStart()
        try await request(brain)
        toggle.state = .on
        NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try require(BrainPreferences(defaults: defaults).saveConversations, "switch writes the preference")
        try await request(brain)
        brain.sessionDidStop()
        brain.sessionWillStart()
        try await request(brain)
        toggle.state = .off
        NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        try await request(brain)
        brain.sessionDidStop()
        brain.sessionWillStart()
        try await request(brain)
        let stores = await traffic.stores
        try require(stores == [false, false, true, true, false], "session policy survives client rebuilds")
        toggle.state = .on
        NSApp.sendAction(toggle.action!, to: toggle.target, from: toggle)
        defaults.synchronize()
    }

    private func request(_ brain: BrainComposition) async throws {
        let transcript = RollingTranscript()
        transcript.append(.init(speaker: .them, text: "Explain a binary search invariant.", at: 0))
        let route = brain.makeConfiguredRoute(brain.preferences.route, proxy: nil,
            keys: [.openAIAPIKey: "synthetic-key"], effort: .low, sessionDirectory: output)
        let driver = CoachDriver(config: .default, transcript: transcript, route: route,
            screen: SettingsHarnessScreen(), overlay: SettingsHarnessOverlay(), clock: SystemClock())
        liveCoachDriver = driver
        let outcome = await driver.handleTrigger(.manualHint)
        await driver.cancelBackgroundWork()?.value
        liveCoachDriver = nil
        try require(outcome == .spoke, "synthetic request succeeds")
    }

    func reportBrainError(_ error: UserFacingError, context: UserFacingError.PresentationContext) {}
    func brainTargetDidChange(_ target: BrainTarget?) {}
    func brainRecoveryDidChange(_ provider: BrainProvider?) {}
    func brainCycleDidFail(_ provider: BrainProvider) {}
}

private actor SettingsHarnessTraffic {
    private(set) var stores: [Bool] = []
    func send(_ request: URLRequest) throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse?) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        guard let store = body?["store"] as? Bool else { throw CocoaError(.coderValueNotFound) }
        stores.append(store)
        let reply = #"{"output":[{"type":"function_call","call_id":"hint","name":"speak","arguments":"{\"hint\":\"State the invariant.\"}"}]}"#
        return (AsyncThrowingStream { $0.yield(Data(reply.utf8)); $0.finish() },
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}

private struct SettingsHarnessScreen: ScreenCapturing {
    func capture(_ selection: ScreenCaptureSelection) -> ScreenSnapshot? { nil }
    func cancelCapture() {}
}

private final class SettingsHarnessOverlay: OverlayRendering {
    func render(_ hint: String) {}
}
#endif
