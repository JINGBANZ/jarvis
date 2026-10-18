#if JARVIS_LIVE_E2E
import AppKit
import JarvisCore

@MainActor
final class ReferenceHarnessAppDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    let bundle: URL
    private var task: Task<Void, Never>?
    var supervisor: ReferenceHelperSupervisor?
    var results: [[String: Any]] = []
    private var terminating = false

    init(arguments: [String] = CommandLine.arguments) throws {
        guard Bundle.main.infoDictionary?["JarvisDevelopmentBuild"] as? Bool == true,
              let index = arguments.firstIndex(of: "--reference-harness-output"),
              arguments.indices.contains(index + 1) else { throw CocoaError(.fileWriteNoPermission) }
        let root = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        output = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let base = root.appendingPathComponent(".jarvis/reference-harness")
        guard output.deletingLastPathComponent() == base,
              output.resolvingSymlinksInPath() == output,
              FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteNoPermission) }
        bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ReferenceHelper")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // ghost-mode-allowed: explicit synthetic References harness
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: output.appendingPathComponent("app.pid"))
        task = Task {
            var failure = ""
            do { try await run() } catch { failure = String(describing: error) }
            let report: [String: Any] = ["status": failure.isEmpty ? "passed" : "failed", "failure": failure,
                "cases": results, "os": ProcessInfo.processInfo.operatingSystemVersionString]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("results.json"))
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.appendingPathComponent("results.json").path)
            } catch { fputs("Reference harness: result write failed\n", stderr) }
            try? Data().write(to: output.appendingPathComponent("quit-invoked"))
            NSApp.terminate(nil) // ghost-mode-allowed: explicit synthetic References harness completion
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let supervisor else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        // terminateLater runs AppKit's termination loop, which does not service MainActor tasks.
        Task {
            await supervisor.stop()
            try? Data().write(to: self.output.appendingPathComponent("quit-finished"))
            self.supervisor = nil
            sender.terminate(nil) // ghost-mode-allowed: complete the explicit harness Quit after cleanup
        }
        return .terminateCancel
    }

    private struct HelperIdentity: Decodable { let pid: Int32 }

    func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain: "ReferenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }

    private func run() async throws {
        if CommandLine.arguments.contains("--reference-harness-quit-only") {
            let helper = ReferenceHelperSupervisor(bundle: bundle, home: output.appendingPathComponent("store"))
            supervisor = helper
            try await helper.start()
            results.append(["case": "application-quit", "helper_pid": helper.processIdentifier!])
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--reference-harness-case"),
           CommandLine.arguments.indices.contains(index + 1) {
            try await runPhaseFourChecks(selection: CommandLine.arguments[index + 1])
            let helper = ReferenceHelperSupervisor(bundle: bundle, home: output.appendingPathComponent("quit-store"))
            supervisor = helper
            try await helper.start()
            results.append(["case": "application-quit", "helper_pid": helper.processIdentifier!])
            return
        }
        try await runPhaseFourChecks(selection: "all")
        let fixture = output.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "Uniquequasar synthetic reference. 😀é\n".write(to: fixture.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let store = output.appendingPathComponent("store")
        let sentinel = output.appendingPathComponent("hostile-helper-executed")
        let real = ReferenceHelperSupervisor(bundle: bundle, home: store)
        supervisor = real
        let clock = ContinuousClock()
        let launched = clock.now
        async let first: Void = real.start()
        async let second: Void = real.start()
        try await first; try await second
        let startup = launched.duration(to: clock.now)
        let metrics = Process()
        metrics.executableURL = URL(fileURLWithPath: "/bin/ps")
        metrics.arguments = ["-o", "rss=", "-p", String(real.processIdentifier!)]
        let metricOutput = Pipe()
        metrics.standardOutput = metricOutput
        metrics.standardError = FileHandle.nullDevice
        try metrics.run()
        let rss = String(decoding: metricOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        metrics.waitUntilExit()
        try require(metrics.terminationStatus == 0 && Int(rss) != nil, "idle RSS measurement")
        try await runAccessChecks(real: real, fixture: fixture, store: store,
                                  startup: startup, idleRSS: Int(rss)!)
        try require(!FileManager.default.fileExists(atPath: sentinel.path), "bundle-only executable")
        supervisor = nil

        for fault in ["startup-hang", "startup-malformed", "startup-partial", "startup-exit", "exit", "duplicate", "out-of-order", "cancel", "blocked-stdin", "blocked-output"] {
            let home = output.appendingPathComponent(fault)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fault.write(to: home.appendingPathComponent("fault"), atomically: true, encoding: .utf8)
            let fake = ReferenceHelperSupervisor(bundle: bundle, home: home, testFault: true, startupTimeout: .milliseconds(300))
            supervisor = fake
            let begin = clock.now
            if fault.hasPrefix("startup-") {
                do { try await fake.start(); throw CocoaError(.coderInvalidValue) }
                catch is CocoaError { throw CocoaError(.coderInvalidValue) }
                catch {}
            } else {
                try await fake.start()
                guard let data = fake.handshake,
                      let handshake = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "ReferenceHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid fake handshake"])
                }
                try require(handshake["secret_present"] as? Bool == false, "credential environment removed")
                if fault == "out-of-order" {
                    async let a = fake.request("one")
                    async let b = fake.request("two")
                    _ = try await (a, b)
                } else if fault == "cancel" {
                    let request = Task { try await fake.request("hold") }
                    try await Task.sleep(for: .milliseconds(40))
                    request.cancel()
                    do { _ = try await request.value; throw CocoaError(.coderInvalidValue) }
                    catch is CancellationError {}
                } else {
                    let payload = fault == "blocked-stdin" ? try json(["padding": String(repeating: "x", count: 900_000)]) : Data("{}".utf8)
                    if fault == "duplicate" {
                        _ = try await fake.request("fault", payload: payload, timeout: .milliseconds(150))
                        let duplicateDeadline = clock.now + .seconds(4)
                        let duplicatePID = fake.processIdentifier!
                        while kill(duplicatePID, 0) == 0, clock.now < duplicateDeadline {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        try require(kill(duplicatePID, 0) != 0 && errno == ESRCH, "duplicate reply terminates helper")
                    } else {
                        do {
                            _ = try await fake.request("fault", payload: payload, timeout: .milliseconds(150))
                            throw CocoaError(.coderInvalidValue)
                        } catch is ReferenceHelperSupervisor.Failure {}
                    }
                }
            }
            let requestElapsed = begin.duration(to: clock.now)
            try require(requestElapsed < .seconds(5), "request bounded \(fault)")
            await fake.stop()
            let pidText = try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)
            let fakePID = Int32(pidText)!
            try require(kill(fakePID, 0) != 0 && errno == ESRCH, "reaped \(fault)")
            let elapsed = begin.duration(to: clock.now)
            try require(elapsed < .seconds(6), "bounded \(fault)")
            results.append(["case": fault, "elapsed": String(describing: elapsed)])
            supervisor = nil
        }
        let raceHome = output.appendingPathComponent("stop-during-start")
        try FileManager.default.createDirectory(at: raceHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try "startup-hang".write(to: raceHome.appendingPathComponent("fault"), atomically: true, encoding: .utf8)
        let racing = ReferenceHelperSupervisor(bundle: bundle, home: raceHome, testFault: true, startupTimeout: .milliseconds(300))
        supervisor = racing
        let starting = Task { try await racing.start() }
        try await Task.sleep(for: .milliseconds(50))
        await racing.stop()
        do { try await starting.value; throw CocoaError(.coderInvalidValue) }
        catch is ReferenceHelperSupervisor.Failure {}
        let racePID = Int32(try String(contentsOf: raceHome.appendingPathComponent("pid"), encoding: .utf8))!
        try require(kill(racePID, 0) != 0 && errno == ESRCH, "startup race reaped")
        results.append(["case": "stop-during-start"])
        supervisor = real
        try await real.start()
        let quitPID = real.processIdentifier!
        results.append(["case": "application-quit", "helper_pid": quitPID])
    }
}
#endif
