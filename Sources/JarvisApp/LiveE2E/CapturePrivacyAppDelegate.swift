#if JARVIS_LIVE_E2E
import AppKit
import JarvisBrainProviders
import JarvisCore
import JarvisOverlay

@MainActor
final class CapturePrivacyAppDelegate: NSObject, NSApplicationDelegate {
    private struct Phase: Codable {
        let name: String
        let measurement: CapturePrivacyStream.Measurement
        var expectsVisibleContent = false
        var passed: Bool {
            measurement.frames > 0 && (expectsVisibleContent
                ? measurement.markerFrames > 0 : measurement.markerFrames == 0)
        }
    }

    private let output: URL
    private let phaseDuration: Duration
    private var task: Task<Void, Never>?
    private var phases: [Phase] = []

    init(arguments: [String] = CommandLine.arguments) throws {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard Bundle.main.object(forInfoDictionaryKey: "JarvisDevelopmentBuild") as? Bool == true,
              let flag = arguments.firstIndex(of: "--capture-privacy-output-dir"),
              arguments.indices.contains(flag + 1) else { throw CocoaError(.fileWriteNoPermission) }
        let output = URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL
        let base = root.appendingPathComponent(".jarvis/capture-privacy", isDirectory: true)
        guard output.deletingLastPathComponent() == base,
              output.resolvingSymlinksInPath() == output,
              FileManager.default.fileExists(atPath: output.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        self.output = output
        var seconds = 1.0
        if let flag = arguments.firstIndex(of: "--capture-privacy-hold-seconds") {
            guard arguments.indices.contains(flag + 1), let value = Double(arguments[flag + 1]),
                  value.isFinite, (1...30).contains(value) else { throw CocoaError(.coderInvalidValue) }
            seconds = value
        }
        phaseDuration = .milliseconds(Int64(seconds * 1_000))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: explicit capture-privacy test
        task = Task {
            var failure: String?
            do { try await run() } catch { failure = error.localizedDescription }
            do {
                let report: [String: Any] = [
                    "status": failure == nil && phases.allSatisfy(\.passed) ? "passed" : "failed",
                    "failure": failure ?? "",
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "bundleID": Bundle.main.bundleIdentifier ?? "",
                    "captureAPI": "ScreenCaptureKit.SCStream; display capture; no excluded windows/apps",
                    "unverifiedMeetingApps": ["Zoom", "Google Meet", "Microsoft Teams"],
                    "phases": try JSONSerialization.jsonObject(with: JSONEncoder().encode(phases)),
                ]
                try TranscriptionBenchmarkFiles.write(
                    JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                    named: "results.json", to: output)
                try TranscriptionBenchmarkFiles.createMarker(named: "finished", in: output)
            } catch {
                fputs("Capture privacy: could not write the result: \(error)\n", stderr)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { task?.cancel() }

    private func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "CapturePrivacy", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Screen Recording is not granted to Jarvis Dev. Grant it explicitly, then rerun."])
        }
        guard let value = ProcessInfo.processInfo.environment["JARVIS_TEST_DISPLAY_ID"],
              let target = UInt32(value),
              let screen = NSScreen.screens.first(where: {
                  $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == target
              }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw CocoaError(.featureUnsupported) }
        let stream = CapturePrivacyStream()
        try await stream.start(displayID: displayID)
        do {
            try await Task.sleep(for: .milliseconds(700))
            try await phase("marker-free-baseline", stream: stream) {}
            let probe = NSPanel(contentRect: NSRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100,
                                                   width: 400, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            probe.level = .floating
            probe.hidesOnDeactivate = false
            probe.setFrameOrigin(NSPoint(x: screen.frame.midX - 200, y: screen.frame.midY - 100))
            try CapturePrivacyMarkerView.attach(to: probe)
            defer { probe.orderOut(nil) }
            stream.beginPhase()
            probe.orderFrontRegardless() // ghost-mode-allowed: positive control for explicit capture test
            try await Task.sleep(for: phaseDuration)
            phases.append(Phase(name: "unprotected-positive-control", measurement: try stream.endPhase(),
                                expectsVisibleContent: true))
            probe.orderOut(nil)
            try await Task.sleep(for: .milliseconds(300))
            let box = OverlayBoxPanel(contentSize: NSSize(width: 560, height: 320))
            defer { box.setSessionLive(false) }
            var overlay: NSWindow?
            try await phase("session-start", stream: stream) {
                box.setSessionLive(true)
                guard let window = NSApp.windows.first(where: {
                    $0 is NSPanel && $0 !== probe && $0.level == .floating && $0.isVisible
                }) else { throw CocoaError(.coderInvalidValue) }
                window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                              y: screen.frame.midY - window.frame.height / 2))
                overlay = window
                try CapturePrivacyMarkerView.attach(to: window)
            }
            stream.beginPhase()
            for index in 1...8 {
                box.showReplyProgress(BrainReplyProgress(
                    hint: String(repeating: "Private synthetic coaching. ", count: index),
                    hintComplete: index == 8, detailMarkdown: "```swift\nlet fixture = \(index)\n```"))
                try await Task.sleep(for: .milliseconds(150))
            }
            _ = box.deliver("Private synthetic coaching.", detail: ReplyDetail(markdown: "```swift\nlet fixture = 8\n```"))
            try await Task.sleep(for: phaseDuration)
            phases.append(Phase(name: "streaming-and-detail", measurement: try stream.endPhase()))
            try await phase("resize", stream: stream) {
                guard let overlay, overlay.isVisible else { throw CocoaError(.coderInvalidValue) }
                overlay.setContentSize(NSSize(width: 640, height: 380))
            }
            try await checkSettings(stream: stream, screen: screen)
            guard overlay?.isVisible == true else { throw CocoaError(.coderInvalidValue) }
            try await phase("session-stop", stream: stream) { box.setSessionLive(false) }
            try await phase("session-restart", stream: stream) {
                box.setSessionLive(true)
                guard overlay?.isVisible == true else { throw CocoaError(.coderInvalidValue) }
                _ = box.deliver("Synthetic restart.", detail: nil)
            }
            try await phase("unprotected-final-control", stream: stream, expectsVisibleContent: true) {
                probe.orderFrontRegardless() // ghost-mode-allowed: final control for explicit capture test
            }
        } catch {
            let failure = error
            try await stream.stop()
            throw failure
        }
        try await stream.stop()
    }

    private func checkSettings(stream: CapturePrivacyStream, screen: NSScreen) async throws {
        let suite = "com.jarvis.capture-privacy.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.coderInvalidValue) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let supervisor = LocalProxySupervisor(executable: nil, home: output.appendingPathComponent("proxy"),
            launcher: AppProcessComposition.makeLauncher())
        let brain = BrainPreferences(defaults: defaults)
        let signIns = SubscriptionSignIns(supervisor: supervisor)
        let hub = SettingsHubModel(
            brainPreferences: brain, transcriptionPreferences: TranscriptionPreferences(defaults: defaults),
            screenPreferences: ScreenCapturePreferences(defaults: defaults), appearance: OverlayAppearance(defaults: defaults),
            secrets: FileSecretStore(directoryURL: output.appendingPathComponent("empty-secrets")), signIns: signIns)
        let viewer = ActivityViewer(log: .shared, store: SessionStore(base: output, current: nil),
            launcher: AppProcessComposition.makeLauncher())
        let settings = SettingsWindow(home: SettingsHome(model: hub), sections: [ActivitySection(viewer: viewer)], hub: hub)
        defer {
            NSApp.windows.first { $0.title == "Jarvis Settings" }?.close()
            viewer.teardown()
        }
        try await phase("settings-open-with-idle-overlay", stream: stream) {
            settings.show()
            guard let window = NSApp.windows.first(where: { $0.title == "Jarvis Settings" && $0.isVisible })
            else { throw CocoaError(.coderInvalidValue) }
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - window.frame.width / 2,
                                          y: screen.frame.midY - window.frame.height / 2))
            try CapturePrivacyMarkerView.attach(to: window)
        }
        try await phase("activity-page", stream: stream) { settings.open(.activity) }
        try await phase("settings-close-with-idle-overlay", stream: stream) {
            guard let window = NSApp.windows.first(where: { $0.title == "Jarvis Settings" && $0.isVisible })
            else { throw CocoaError(.coderInvalidValue) }
            window.close()
        }
    }

    private func phase(_ name: String, stream: CapturePrivacyStream, expectsVisibleContent: Bool = false,
                       action: () throws -> Void) async throws {
        try TranscriptionBenchmarkFiles.writeText(name, named: "phase.txt", to: output)
        stream.beginPhase()
        try action()
        try await Task.sleep(for: phaseDuration)
        phases.append(Phase(name: name, measurement: try stream.endPhase(), expectsVisibleContent: expectsVisibleContent))
    }
}
#endif
