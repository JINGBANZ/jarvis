import AppKit
import XCTest

@MainActor
final class AudioFixtureTests: XCTestCase {
    private let identifier = "com.jarvis.release-route-fixture"
    private var applications: [NSRunningApplication] = []
    private var fixture: URL?
    private var evidence: URL?

    override func record(_ issue: XCTIssue) {
        if let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] {
            let evidence = URL(fileURLWithPath: path)
            let location = issue.sourceCodeContext.location
            let ownSource = location?.fileURL.lastPathComponent == "AudioFixtureTests.swift"
            let value: [String: Any] = ["issueType": issue.type.rawValue, "sourceIsHarness": ownSource,
                                        "line": ownSource ? location?.lineNumber ?? 0 : 0]
            do {
                try JSONSerialization.data(withJSONObject: value).write(
                    to: evidence.appendingPathComponent("audio-issue.json"), options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
            } catch { print("Could not record the scalar audio issue location") }
        }
        super.record(issue)
    }

    func testIndependentSyntheticRoutes() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard NSUserName() == "runner", NSHomeDirectory() == "/Users/runner",
              environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        else { throw FixtureFailure.invalidEnvironment }
        let directory = URL(fileURLWithPath: try XCTUnwrap(environment["JARVIS_READINESS_EVIDENCE"]))
        evidence = directory
        let app = URL(fileURLWithPath: try XCTUnwrap(environment["JARVIS_READINESS_AUDIO_FIXTURE"]))
        XCTAssertEqual(app.resolvingSymlinksInPath(), app)
        XCTAssertTrue(app.path.hasPrefix(directory.appendingPathComponent("derived/").path))
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
        fixture = app
        addTeardownBlock { @MainActor [self] in try cleanUp() }

        try stage("fixture-consents")
        let acknowledgement = directory.appendingPathComponent("fixture-consents.ack")
        var consentTiming: [String: Any] = ["launchRequestedUptime": ProcessInfo.processInfo.systemUptime]
        try writeConsentTiming(consentTiming)
        let authorization = try await launch(["--authorize", "--acknowledgement", acknowledgement.path,
                                        "--receipt", directory.appendingPathComponent("private-authorize.json").path])
        consentTiming["launchReturnedUptime"] = ProcessInfo.processInfo.systemUptime
        consentTiming["launchReturnedFinishedLaunching"] = authorization.isFinishedLaunching
        consentTiming["launchReturnedTerminated"] = authorization.isTerminated
        try writeConsentTiming(consentTiming)
        var grants: Set<String> = []
        for _ in 0..<2 {
            let (permission, button) = try nextConsent(excluding: grants)
            consentTiming[permission + "AllowStartedUptime"] = ProcessInfo.processInfo.systemUptime
            try writeConsentTiming(consentTiming)
            button.click()
            consentTiming[permission + "AllowCompletedUptime"] = ProcessInfo.processInfo.systemUptime
            try writeConsentTiming(consentTiming)
            XCTAssertTrue(grants.insert(permission).inserted)
            try stage("fixture-\(permission)-allowed")
        }
        XCTAssertEqual(grants, ["microphone", "audio"])
        try waitForReady(name: "authorize", mode: "authorize", phase: "consent", stage: "authorization-ready", timeout: 10)
        let temporary = directory.appendingPathComponent("fixture-consents.pending")
        let bytes = Data("fixture-native-consents-accepted-v1\n".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600]))
        try FileManager.default.moveItem(at: temporary, to: acknowledgement)
        try waitForExit(authorization, timeout: 10)
        let consent: [String: Any] = ["microphoneAllowObserved": true, "systemAudioAllowObserved": true,
                                     "captureGrantProven": false]
        try JSONSerialization.data(withJSONObject: consent).write(
            to: directory.appendingPathComponent("fixture-consents.json"), options: .withoutOverwriting)

        for phase in ["mic", "system"] {
            try stage("\(phase)-route")
            let capture = try await launch(["--capture", "\(phase)-only", "--mic-uid", "BlackHole16ch_UID",
                                      "--system-uid", "BlackHole2ch_UID", "--receipt",
                                      directory.appendingPathComponent("private-\(phase)-capture.json").path])
            try waitForReady(name: "\(phase)-capture", mode: "capture", phase: "\(phase)-only", stage: "ready", timeout: 15)
            let emitter = try await launch(["--emit", phase, "--device-uid", phase == "mic" ? "BlackHole16ch_UID" : "BlackHole2ch_UID",
                                      "--receipt", directory.appendingPathComponent("private-\(phase)-emit.json").path])
            try waitForReady(name: "\(phase)-emit", mode: "emit", phase: phase, stage: "ready", timeout: 5)
            try waitForExit(capture, timeout: 15)
            try waitForExit(emitter, timeout: 10)
            XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty)
        }
        try stage("measurements-complete")
    }

    private func nextConsent(excluding accepted: Set<String>) throws -> (String, XCUIElement) {
        var found: (String, XCUIElement)?
        let owners = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                      "com.apple.accessibility.universalAccessAuthWarn", "com.apple.AccessibilityUIServer"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            var matches: [(String, XCUIElement)] = []
            for owner in owners where !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty {
                let app = XCUIApplication(bundleIdentifier: owner)
                let dialogs = app.dialogs.allElementsBoundByIndex
                let containers = dialogs.isEmpty ? app.windows.allElementsBoundByIndex : dialogs
                for container in containers {
                    let text = container.staticTexts.allElementsBoundByIndex.map {
                        $0.label + " " + ($0.value as? String ?? "")
                    }.joined(separator: "\n")
                    guard text.contains("Jarvis Route Fixture") else { continue }
                    let permissions = ["microphone", "audio"].filter { text.localizedCaseInsensitiveContains($0) }
                    guard permissions.count == 1, let permission = permissions.first, !accepted.contains(permission) else { continue }
                    let buttons = container.buttons.matching(NSPredicate(format: "label == 'Allow' OR title == 'Allow'"))
                    if buttons.count == 1, buttons.element.isEnabled, buttons.element.isHittable {
                        matches.append((permission, buttons.element))
                    }
                }
            }
            guard matches.count == 1 else { return false }
            found = matches[0]
            return true
        }, object: nil)
        let outcome = XCTWaiter.wait(for: [ready], timeout: 25)
        if outcome != .completed {
            try PermissionOwnerEvidence.record(directory: XCTUnwrap(evidence), filename: "audio-permission-owner.json")
        }
        XCTAssertEqual(outcome, .completed,
                       "The fixture requires its own unique native Allow action")
        return try XCTUnwrap(found)
    }

    private func launch(_ arguments: [String]) async throws -> NSRunningApplication {
        let fixture = try XCTUnwrap(fixture)
        let prior = Set(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = arguments
        for key in ["GITHUB_ACTIONS", "RUNNER_OS", "RUNNER_ENVIRONMENT", "GITHUB_WORKSPACE"] {
            configuration.environment[key] = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
        }
        // LaunchServices returns the actual fixture identity without an untracked open -W waiter.
        let application = try await NSWorkspace.shared.openApplication(at: fixture, configuration: configuration) // ghost-mode-allowed: hosted external fixture explicitly launches synthetic route probes
        applications.append(application)
        XCTAssertFalse(prior.contains(application.processIdentifier))
        XCTAssertEqual(application.bundleURL?.resolvingSymlinksInPath(), fixture)
        XCTAssertEqual(application.bundleIdentifier, identifier)
        #if arch(arm64)
        let architecture = NSBundleExecutableArchitectureARM64
        #elseif arch(x86_64)
        let architecture = NSBundleExecutableArchitectureX86_64
        #else
        #error("Release ready check requires a supported native Mac architecture")
        #endif
        XCTAssertEqual(application.executableArchitecture, architecture)
        return application
    }

    private func waitForReady(name: String, mode: String, phase: String, stage: String, timeout: TimeInterval) throws {
        let path = try XCTUnwrap(evidence).appendingPathComponent("private-\(name).ready")
        let expected: [String: AnyHashable] = ["schemaVersion": 1, "mode": mode, "phase": phase, "stage": stage]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: path), data.count < 1_024,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: AnyHashable] else { return false }
            return value == expected
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed,
                       "The exact fixture phase must report readiness before its finite measurement")
    }

    private func waitForExit(_ application: NSRunningApplication, timeout: TimeInterval) throws {
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in application.isTerminated }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: timeout), .completed)
    }

    private func stage(_ value: String) throws {
        let record: [String: Any] = ["stage": value, "uptime": ProcessInfo.processInfo.systemUptime]
        try JSONSerialization.data(withJSONObject: record).write(
            to: try XCTUnwrap(evidence).appendingPathComponent("audio-stage.json"), options: .atomic)
    }

    private func writeConsentTiming(_ values: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: values).write(
            to: try XCTUnwrap(evidence).appendingPathComponent("audio-consent-timing.json"), options: .atomic)
    }

    private func cleanUp() throws {
        let fixture = try XCTUnwrap(fixture)
        let children = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        for child in children {
            XCTAssertEqual(child.bundleURL?.resolvingSymlinksInPath(), fixture)
            if child.bundleURL?.resolvingSymlinksInPath() == fixture { child.terminate() }
        }
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: self.identifier).isEmpty
                && self.applications.allSatisfy { $0.isTerminated }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 10), .completed,
                       "All actual fixture instances must exit")
    }

    private enum FixtureFailure: Error { case invalidEnvironment }
}
