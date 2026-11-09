import AppKit
import os
import XCTest

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    let bundleID = "com.jarvis.coach"
    var application: XCUIApplication?
    var installedURL: URL?
    var audioDevices: ReleaseAudioDevices?
    private nonisolated let pendingRelaunch = OSAllocatedUnfairLock<(pid: pid_t, installedURL: URL, operation: String)?>(initialState: nil)

    override func record(_ issue: XCTIssue) {
        UIIssueEvidence.record(issue, firstFilename: "ui-issue.json", failureFilename: "ui-failure.json")
        let reference = issue as XCTIssueReference
        var isFailure = (0...5).contains(issue.type.rawValue)
        if reference.responds(to: NSSelectorFromString("isFailure")),
           let value = reference.value(forKey: "isFailure") as? NSNumber {
            isFailure = value.boolValue
        }
        if isFailure { recordRelaunchState() }
        super.record(issue)
    }

    private nonisolated func recordRelaunchState() {
        guard let pending = pendingRelaunch.withLock({ $0 }),
              let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else { return }
        let previousPID = pending.pid
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let replacements = running.filter {
            $0.processIdentifier != previousPID && $0.bundleURL?.resolvingSymlinksInPath() == pending.installedURL
                && $0.executableArchitecture == NSRunningApplication.current.executableArchitecture
        }
        let replacement = replacements.count == 1 ? replacements.first : nil
        let state: [String: Any] = ["previousPID": previousPID, "operation": pending.operation,
                                   "oldProcessPresent": running.contains { $0.processIdentifier == previousPID },
                                   "replacementCount": replacements.count,
                                   "replacementActive": replacement?.isActive ?? false,
                                   "replacementFinishedLaunching": replacement?.isFinishedLaunching ?? false]
        do {
            try JSONSerialization.data(withJSONObject: state).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("relaunch-state.json"), options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
        } catch { print("Could not record the scalar relaunch state") }
    }

    func completePermissionOnboarding(_ initialApp: XCUIApplication) throws -> XCUIApplication {
        var app = initialApp
        var welcome = app.windows["Welcome to Jarvis"]
        let grant = welcome.buttons["Grant Access"]
        XCTAssertTrue(grant.waitForExistence(timeout: 20), "Stored-key precondition must expose ordinary permission onboarding")
        attachEvidence(app, name: "permissions-before-grants")
        recordPermissionState(onboarding: welcome, acceptedConsents: [], reason: .initial)
        var grantProcesses: Set<pid_t> = []
        var acceptedConsents: Set<String> = []
        var reachedReady = false
        var replacementPID: pid_t?
        var completionPath = ""
        for step in 1...12 {
            switch try nextPermissionAction(app: app, onboarding: welcome, acceptedConsents: acceptedConsents,
                                            replacementPID: replacementPID) {
            case .completedAfterRelaunch:
                XCTAssertEqual(try candidateProcessID(), try XCTUnwrap(replacementPID))
                reachedReady = true
                completionPath = "relaunch-automatic"
            case .consent(let permissions, let dialog):
                attachEvidence(name: "permission-consent-selected")
                acceptedConsents.formUnion(permissions)
                if permissions.contains("screen"), dialog.buttons.matching(identifier: "Open System Settings").count == 1 {
                    let previousPID = try candidateProcessID()
                    attachEvidence(name: "permission-settings-click")
                    dialog.buttons["Open System Settings"].click()
                    attachEvidence(name: "permission-settings-clicked")
                    if try grantScreenRecordingInSettings() {
                        app = try waitForReplacement(of: previousPID)
                        welcome = app.windows["Welcome to Jarvis"]
                        replacementPID = try candidateProcessID()
                    }
                    app.activate()
                } else {
                    let allow = consentButtons(in: dialog)
                    XCTAssertEqual(allow.count, 1, "Consent requires one unambiguous Allow control")
                    allow.element.click()
                }
            case .onboarding(let title):
                attachEvidence(app, name: "permission-step-\(step)-\(title)")
                print("permissionStep=\(step) normalAction=\(title)")
                switch title {
                case "Grant Access":
                    let pid = try candidateProcessID()
                    XCTAssertTrue(grantProcesses.insert(pid).inserted,
                                  "A repeated inconclusive permission walk in one process must fail acceptance")
                    welcome.buttons[title].click()
                case "Open System Settings":
                    XCTAssertEqual(grantedPermissionCount(in: welcome), 2,
                                   "The observed screen-settings branch requires microphone and system audio proof")
                    XCTAssertEqual(welcome.staticTexts.matching(identifier: "Refused").count, 1)
                    XCTAssertTrue(welcome.staticTexts["Screen Recording"].exists)
                    let previousPID = try candidateProcessID()
                    welcome.buttons[title].click()
                    if try grantScreenRecordingInSettings() {
                        app = try waitForReplacement(of: previousPID)
                        welcome = app.windows["Welcome to Jarvis"]
                        replacementPID = try candidateProcessID()
                    }
                    acceptedConsents.insert("screen")
                    app.activate()
                case "Quit & Reopen":
                    let previousPID = try candidateProcessID()
                    let relaunch = (pid: previousPID, installedURL: try XCTUnwrap(installedURL), operation: "validation")
                    pendingRelaunch.withLock { $0 = relaunch }
                    XCTAssertEqual(grantedPermissionCount(in: welcome), 2,
                                   "Relaunch requires microphone and system audio proof")
                    XCTAssertEqual(welcome.staticTexts.matching(identifier: "Reopen to finish").count, 1,
                                   "The ordinary relaunch must be offered for the pending screen grant")
                    pendingRelaunch.withLock { $0?.operation = "click" }
                    welcome.buttons[title].click()
                    pendingRelaunch.withLock { $0?.operation = "replacement" }
                    app = try waitForReplacement(of: previousPID)
                    welcome = app.windows["Welcome to Jarvis"]
                    let currentPID = try candidateProcessID()
                    replacementPID = currentPID
                    pendingRelaunch.withLock { $0 = nil }
                case "I’m Ready":
                    XCTAssertEqual(grantedPermissionCount(in: welcome), 3, "Every permission must be positively granted")
                    XCTAssertTrue(acceptedConsents.contains("microphone"), "Fresh acceptance must grant native microphone consent")
                    XCTAssertTrue(acceptedConsents.contains("audio"), "Fresh acceptance must grant native system-audio consent")
                    XCTAssertTrue(acceptedConsents.contains("screen"), "Fresh acceptance must observe native screen-recording consent")
                    welcome.buttons[title].click()
                    reachedReady = true
                    completionPath = "ready-button"
                default:
                    throw ReadinessFailure("Unexpected permission action: \(title)")
                }
            }
            if reachedReady { break }
        }
        XCTAssertTrue(reachedReady, "The bounded permission journey must complete through the ordinary app flow")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: welcome)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed,
                       "Permission onboarding must actually close")
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.persistedOnboardingCompleted()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 15), .completed,
                       "Normal onboarding must persist completion; read the actual preference file afresh")
        XCTAssertTrue(app.statusItems["Jarvis is stopped"].waitForExistence(timeout: 30),
                      "Normal onboarding must prove every grant before entering the stopped app")
        let evidence = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
        let completion: [String: Any] = ["path": completionPath, "nativeConsentsObserved": acceptedConsents == ["microphone", "audio", "screen"],
                                          "persistedCompletion": persistedOnboardingCompleted(), "welcomeAbsent": !welcome.exists,
                                          "stoppedStatusPresent": app.statusItems["Jarvis is stopped"].exists,
                                          "replacementVerified": replacementPID != nil,
                                          "nativeInstalledProcessVerified": try candidateProcessID() > 0]
        try JSONSerialization.data(withJSONObject: completion).write(
            to: URL(fileURLWithPath: evidence).appendingPathComponent("permission-completion.json"), options: .atomic)
        return app
    }

    private enum PermissionAction {
        case consent(Set<String>, XCUIElement)
        case onboarding(String)
        case completedAfterRelaunch
    }

    private func nextPermissionAction(app: XCUIApplication, onboarding: XCUIElement, acceptedConsents: Set<String>,
                                      replacementPID: pid_t?) throws -> PermissionAction {
        let owners = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                      "com.apple.accessibility.universalAccessAuthWarn", "com.apple.AccessibilityUIServer"]
        var captured: Set<String> = []
        var action: PermissionAction?
        var consentOwner: String?
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if let replacementPID, acceptedConsents == ["microphone", "audio", "screen"] {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID)
                if running.count == 1, running[0].processIdentifier == replacementPID,
                   running[0].bundleURL?.resolvingSymlinksInPath() == self.installedURL,
                   running[0].executableArchitecture == NSRunningApplication.current.executableArchitecture,
                   !onboarding.exists, self.persistedOnboardingCompleted(), app.statusItems["Jarvis is stopped"].exists {
                    action = .completedAfterRelaunch
                    return true
                }
            }
            let titles = ["Grant Access", "Open System Settings", "Quit & Reopen", "I’m Ready"].filter { title in
                let permitted: Bool
                switch title {
                case "Grant Access":
                    let fresh = acceptedConsents.isEmpty && onboarding.staticTexts.matching(identifier: "Needed").count == 3
                    var replacementNeedsWalk = false
                    if let replacementPID, acceptedConsents == ["microphone", "audio"],
                       self.grantedPermissionCount(in: onboarding) == 1,
                       onboarding.staticTexts.matching(identifier: "Needed").count == 2 {
                        let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID)
                        replacementNeedsWalk = running.count == 1 && running[0].processIdentifier == replacementPID
                            && running[0].bundleURL?.resolvingSymlinksInPath() == self.installedURL
                            && running[0].executableArchitecture == NSRunningApplication.current.executableArchitecture
                    }
                    permitted = fresh || replacementNeedsWalk
                case "Open System Settings":
                    permitted = acceptedConsents.isSuperset(of: ["microphone", "audio"])
                        && self.grantedPermissionCount(in: onboarding) == 2
                        && onboarding.staticTexts.matching(identifier: "Refused").count == 1
                case "Quit & Reopen":
                    permitted = self.grantedPermissionCount(in: onboarding) == 2
                        && onboarding.staticTexts.matching(identifier: "Reopen to finish").count == 1
                default:
                    permitted = acceptedConsents == ["microphone", "audio", "screen"]
                        && self.grantedPermissionCount(in: onboarding) == 3
                }
                guard permitted else { return false }
                let buttons = onboarding.buttons.matching(identifier: title)
                return buttons.count == 1 && buttons.element.isEnabled && buttons.element.isHittable
            }
            if titles.count == 1 {
                action = .onboarding(titles[0])
                return true
            }
            var matches: [(String, Set<String>, XCUIElement)] = []
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] else { return false }
            let visibleOwners = Set(windows.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
            var discovery: [String: [String: Int]] = [:]
            func recordDiscovery() {
                guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else { return }
                do {
                    try JSONSerialization.data(withJSONObject: discovery).write(
                        to: URL(fileURLWithPath: path).appendingPathComponent("permission-discovery.json"), options: .atomic)
                } catch { XCTFail("Could not record scalar native-dialog discovery") }
            }
            for identifier in owners {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                let visible = running.filter { visibleOwners.contains($0.processIdentifier) }.count
                var counts = ["running": running.count, "visibleOwners": visible, "dialogs": 0, "containers": 0, "jarvisTextMatches": 0,
                              "fixtureTextMatches": 0,
                              "jarvisLabelMatches": 0, "jarvisTitleMatches": 0, "jarvisStaticTextMatches": 0,
                              "microphoneMatches": 0, "audioMatches": 0, "screenMatches": 0,
                              "allowButtons": 0, "openSettingsButtons": 0]
                discovery[identifier] = counts
                guard visible > 0 else { continue }
                counts["queryStartedMilliseconds"] = Int(ProcessInfo.processInfo.systemUptime * 1_000)
                discovery[identifier] = counts
                recordDiscovery()
                let candidate = XCUIApplication(bundleIdentifier: identifier)
                if captured.insert(identifier).inserted {
                    self.attachEvidence(candidate, name: "permission-owner-first-\(identifier)")
                }
                let dialogs = candidate.dialogs.allElementsBoundByIndex
                let containers = dialogs.isEmpty ? candidate.windows.allElementsBoundByIndex : dialogs
                counts["dialogs"] = dialogs.count
                counts["containers"] = containers.count
                for container in containers {
                    let staticText = container.staticTexts.allElementsBoundByIndex.map {
                        $0.label + " " + ($0.value as? String ?? "")
                    }.joined(separator: "\n")
                    let label = container.label
                    let title = container.title
                    let text = [label, title, staticText].joined(separator: "\n")
                    guard text.localizedCaseInsensitiveContains("Jarvis") else { continue }
                    if text.localizedCaseInsensitiveContains("Jarvis Route Fixture") {
                        counts["fixtureTextMatches", default: 0] += 1
                        continue
                    }
                    if label.localizedCaseInsensitiveContains("Jarvis") { counts["jarvisLabelMatches", default: 0] += 1 }
                    if title.localizedCaseInsensitiveContains("Jarvis") { counts["jarvisTitleMatches", default: 0] += 1 }
                    if staticText.localizedCaseInsensitiveContains("Jarvis") { counts["jarvisStaticTextMatches", default: 0] += 1 }
                    counts["jarvisTextMatches", default: 0] += 1
                    let permissions = Set(["microphone", "audio", "screen"].filter {
                        text.localizedCaseInsensitiveContains($0)
                    })
                    guard !permissions.isEmpty else { continue }
                    for permission in permissions { counts[permission + "Matches", default: 0] += 1 }
                    let allow = self.consentButtons(in: container)
                    counts["allowButtons", default: 0] += allow.count
                    counts["openSettingsButtons", default: 0] += container.buttons.matching(identifier: "Open System Settings").count
                    let opensSettings = permissions.contains("screen")
                        && container.buttons.matching(identifier: "Open System Settings").count == 1
                    if allow.count == 1 || opensSettings { matches.append((identifier, permissions, container)) }
                }
                counts["queryFinishedMilliseconds"] = Int(ProcessInfo.processInfo.systemUptime * 1_000)
                discovery[identifier] = counts
                recordDiscovery()
            }
            recordDiscovery()
            if matches.count == 1 {
                let (owner, permissions, dialog) = matches[0]
                self.attachEvidence(name: "permission-consent-matched")
                action = .consent(permissions, dialog)
                consentOwner = owner
                return true
            }
            return false
        }, object: nil)
        let waitStarted = ProcessInfo.processInfo.systemUptime
        let result = XCTWaiter.wait(for: [visible], timeout: 20)
        recordPermissionWait(result, started: waitStarted, filename: "permission-wait.json")
        guard result == .completed, let action else {
            let path = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
            try PermissionOwnerEvidence.record(directory: URL(fileURLWithPath: path), filename: "permission-owner.json")
            recordPermissionState(onboarding: onboarding, acceptedConsents: acceptedConsents, reason: .noAction)
            throw ReadinessFailure("No unique validated system consent or ordinary permission action became available")
        }
        if case .consent(let permissions, _) = action {
            let owner = try XCTUnwrap(consentOwner)
            print("nativeConsent=\(permissions.sorted().joined(separator: ",")) owner=\(owner)")
        }
        return action
    }

    private func recordPermissionWait(_ result: XCTWaiter.Result, started: TimeInterval, filename: String) {
        let outcome: String
        switch result {
        case .completed: outcome = "completed"
        case .timedOut: outcome = "timed-out"
        case .incorrectOrder: outcome = "incorrect-order"
        case .invertedFulfillment: outcome = "inverted-fulfillment"
        case .interrupted: outcome = "interrupted"
        @unknown default: outcome = "unknown"
        }
        guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else { return }
        let receipt: [String: Any] = ["result": outcome, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started]
        do {
            try JSONSerialization.data(withJSONObject: receipt).write(
                to: URL(fileURLWithPath: path).appendingPathComponent(filename), options: .atomic)
        } catch { XCTFail("Could not record the scalar native-permission wait result") }
    }

    private enum PermissionStateReason: String {
        case initial = "initial-permission-state"
        case noAction = "no-unique-permission-action"
    }

    private func recordPermissionState(onboarding: XCUIElement, acceptedConsents: Set<String>, reason: PermissionStateReason) {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else { return }
        let statuses = ["Granted", "Asking…", "Refused", "Needed", "Reopen to finish"]
        let actions = ["Grant Access", "Open System Settings", "Quit & Reopen", "I’m Ready", "Waiting for macOS…"]
        let receipt: [String: Any] = [
            "reason": reason.rawValue,
            "statuses": Dictionary(uniqueKeysWithValues: statuses.map { status in
                (status, onboarding.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", status, status)).count)
            }),
            "actions": Dictionary(uniqueKeysWithValues: actions.map { title in
                let matches = onboarding.buttons.matching(identifier: title)
                return (title, ["count": matches.count,
                                "enabledCount": matches.allElementsBoundByIndex.filter(\.isEnabled).count])
            }),
            "nativeConsents": Dictionary(uniqueKeysWithValues: ["microphone", "audio", "screen"].map {
                ($0, acceptedConsents.contains($0))
            }),
            "systemAudioInconclusive": onboarding.staticTexts["I couldn’t check system audio just now. Try again."].exists,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt)
            let filename = reason == .initial ? "permission-initial.json" : "permission-state.json"
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent(filename), options: .atomic)
        } catch {
            XCTFail("Could not record the scalar permission-wait reason")
        }
    }

    func persistedOnboardingCompleted() -> Bool {
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")
        guard let data = try? Data(contentsOf: preferencesURL),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return values["onboarding.completed"] as? Bool == true
    }

    private func grantedPermissionCount(in onboarding: XCUIElement) -> Int {
        onboarding.staticTexts.matching(NSPredicate(format: "value == 'Granted' OR label == 'Granted'")).count
    }

    func candidateProcessID() throws -> pid_t {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        XCTAssertEqual(running.count, 1, "Exactly one installed candidate must run")
        let candidate = try XCTUnwrap(running.first)
        XCTAssertEqual(candidate.bundleURL?.resolvingSymlinksInPath(), installedURL)
        XCTAssertEqual(candidate.executableArchitecture, NSRunningApplication.current.executableArchitecture)
        return candidate.processIdentifier
    }

    private func waitForReplacement(of previousPID: pid_t) throws -> XCUIApplication {
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID)
            return running.count == 1 && running[0].processIdentifier != previousPID
                && running[0].bundleURL?.resolvingSymlinksInPath() == self.installedURL
                && running[0].executableArchitecture == NSRunningApplication.current.executableArchitecture
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 15), .completed,
                       "Normal Quit & Reopen must replace the installed candidate process")
        let app = XCUIApplication(url: try XCTUnwrap(installedURL))
        application = app
        return app
    }

    private func consentButtons(in dialog: XCUIElement) -> XCUIElementQuery {
        dialog.buttons.matching(NSPredicate(format:
            "label BEGINSWITH[c] 'Allow' OR title BEGINSWITH[c] 'Allow' OR label == 'OK' OR title == 'OK'"))
    }

    private func grantScreenRecordingInSettings() throws -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        func openingState() -> [String: Any] {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            let unique = running.count == 1 ? running.first : nil
            return ["uptime": ProcessInfo.processInfo.systemUptime, "xcuiState": settings.state.rawValue,
                    "processCount": running.count, "uniqueProcessID": unique?.processIdentifier ?? 0,
                    "active": unique?.isActive ?? false, "finishedLaunching": unique?.isFinishedLaunching ?? false,
                    "frontmostIsSettings": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"]
        }
        let evidencePath = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
        let evidenceDirectory = URL(fileURLWithPath: evidencePath)
        let openingURL = evidenceDirectory.appendingPathComponent("recording-open.json")
        var opening: [String: Any] = ["before": openingState()]
        try JSONSerialization.data(withJSONObject: opening).write(to: openingURL, options: .atomic)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
        guard running.count == 1, let existing = running.first, !existing.isTerminated else {
            throw ReadinessFailure("Permission action must launch exactly one System Settings process before activation")
        }
        let existingPID = existing.processIdentifier
        opening["activationRequested"] = true
        try JSONSerialization.data(withJSONObject: opening).write(to: openingURL, options: .atomic)
        settings.activate() // ghost-mode-allowed: external runner brings the opened native permission controls forward
        let waitStarted = ProcessInfo.processInfo.systemUptime
        let opened = settings.wait(for: .runningForeground, timeout: 15)
        let sameProcess = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences")
            .map(\.processIdentifier) == [existingPID]
        opening["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - waitStarted
        opening["waitSucceeded"] = opened
        opening["sameProcess"] = sameProcess
        opening["after"] = openingState()
        try JSONSerialization.data(withJSONObject: opening).write(to: openingURL, options: .atomic)
        if !opened {
            do {
                try PermissionOwnerEvidence.record(directory: evidenceDirectory, filename: "permission-owner.json")
            } catch {
                print("Could not record native ownership after the System Settings foreground wait failed")
            }
        }
        XCTAssertTrue(sameProcess, "Activation must retain the System Settings process opened by the permission action")
        XCTAssertTrue(opened, "Permission action must open System Settings")
        attachEvidence(settings, name: "system-screen-recording-settings")
        let panes = settings.scrollViews.containing(.staticText, identifier: "Screen & System Audio Recording")
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10), "The recording privacy pane must load")
        attachEvidence(settings, name: "recording-pane-loaded")
        XCTAssertEqual(panes.count, 1, "The recording privacy pane must be unambiguous")
        let pane = panes.element
        let screenHeading = pane.staticTexts["Screen & System Audio Recording"]
        let audioOnlyHeading = pane.staticTexts["System Audio Recording Only"]
        XCTAssertTrue(audioOnlyHeading.waitForExistence(timeout: 10))
        attachEvidence(settings, name: "recording-headings-loaded")
        XCTAssertGreaterThan(screenHeading.frame.height, 0)
        XCTAssertGreaterThan(audioOnlyHeading.frame.minY, screenHeading.frame.maxY)
        let sections = pane.outlines.containing(.switch, identifier: "Jarvis_Toggle").allElementsBoundByIndex.filter {
            let frame = $0.frame
            return frame.height > 0 && frame.minY >= screenHeading.frame.maxY && frame.maxY <= audioOnlyHeading.frame.minY
        }
        XCTAssertEqual(sections.count, 1, "Exactly one Jarvis outline must belong to the screen-recording section")
        let section = try XCTUnwrap(sections.first)
        attachEvidence(settings, name: "recording-section-matched")
        XCTAssertEqual(section.staticTexts["Jarvis_Title"].value as? String, "Jarvis")
        XCTAssertEqual(section.switches.matching(identifier: "Jarvis_Toggle").count, 1)
        let toggle = section.switches["Jarvis_Toggle"]
        attachEvidence(settings, name: "recording-toggle-matched")
        let evidence = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
        try JSONSerialization.data(withJSONObject: recordingToggleValue(toggle.value)).write(
            to: URL(fileURLWithPath: evidence).appendingPathComponent("recording-initial.json"), options: .atomic)
        let initialEnabled = try XCTUnwrap(recordingToggleEnabled(toggle.value),
                                           "The native recording switch must expose a known Boolean value")
        if !initialEnabled { toggle.click() }
        let authorized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.recordingToggleEnabled(toggle.value) == true || settings.buttons["Quit & Reopen"].exists
        }, object: nil)
        let authorizationResult = XCTWaiter.wait(for: [authorized], timeout: 45)
        attachEvidence(settings, name: "system-screen-recording-authorization-outcome")
        XCTAssertEqual(authorizationResult, .completed, "Native Settings authorization must enable recording or offer relaunch")
        let sheets = settings.sheets.containing(.button, identifier: "Quit & Reopen")
        let relaunches = sheets.firstMatch.waitForExistence(timeout: 5)
        if relaunches {
            attachEvidence(settings, name: "recording-relaunch-offered")
            XCTAssertEqual(sheets.count, 1, "The native relaunch sheet must be unique")
            let confirmations = sheets.element.buttons.matching(identifier: "Quit & Reopen")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                confirmations.count == 1 && confirmations.element.isEnabled && confirmations.element.isHittable
            }, object: nil)
            let readyResult = XCTWaiter.wait(for: [ready], timeout: 5)
            let count = confirmations.count
            let state: [String: Any] = ["matchingButtons": count,
                "enabled": count == 1 && confirmations.element.isEnabled,
                "hittable": count == 1 && confirmations.element.isHittable,
                "matchingDialogs": settings.dialogs.containing(.button, identifier: "Quit & Reopen").count,
                "matchingSheets": settings.sheets.containing(.button, identifier: "Quit & Reopen").count,
                "matchingAlerts": settings.alerts.containing(.button, identifier: "Quit & Reopen").count]
            let evidence = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
            try JSONSerialization.data(withJSONObject: state).write(
                to: URL(fileURLWithPath: evidence).appendingPathComponent("relaunch-control.json"), options: .atomic)
            XCTAssertEqual(readyResult, .completed, "The unique native relaunch control must become enabled and hittable")
            let confirm = confirmations.element
            confirm.click()
            attachEvidence(settings, name: "recording-relaunch-clicked")
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.recordingToggleEnabled(toggle.value) == true
        }, object: nil)
        let enabledResult = XCTWaiter.wait(for: [enabled], timeout: 5)
        attachEvidence(settings, name: "system-screen-recording-settings-final")
        let currentPanes = settings.scrollViews.containing(.staticText, identifier: "Screen & System Audio Recording")
        var finalState: [String: Any] = ["paneCount": currentPanes.count,
                                        "originalToggle": recordingToggleValue(toggle.value)]
        if currentPanes.count == 1 {
            let currentPane = currentPanes.element
            let heading = currentPane.staticTexts["Screen & System Audio Recording"]
            let audioHeading = currentPane.staticTexts["System Audio Recording Only"]
            let currentSections = currentPane.outlines.containing(.switch, identifier: "Jarvis_Toggle").allElementsBoundByIndex.filter {
                $0.frame.height > 0 && $0.frame.minY >= heading.frame.maxY && $0.frame.maxY <= audioHeading.frame.minY
            }
            finalState["screenSectionCount"] = currentSections.count
            if currentSections.count == 1, let section = currentSections.first {
                let toggles = section.switches.matching(identifier: "Jarvis_Toggle")
                finalState["toggleCount"] = toggles.count
                if toggles.count == 1 { finalState["freshToggle"] = recordingToggleValue(toggles.element.value) }
            }
        }
        try JSONSerialization.data(withJSONObject: finalState).write(
            to: URL(fileURLWithPath: evidence).appendingPathComponent("recording-final.json"), options: .atomic)
        XCTAssertEqual(enabledResult, .completed, "Screen-recording grant must be enabled")
        return relaunches
    }

    private func recordingToggleEnabled(_ value: Any?) -> Bool? {
        if let value = value as? String, ["0", "1"].contains(value) { return value == "1" }
        if let value = value as? NSNumber, value == 0 || value == 1 { return value == 1 }
        return nil
    }

    private func recordingToggleValue(_ value: Any?) -> [String: Any] {
        let enabled = recordingToggleEnabled(value)
        let kind = value is String ? "string" : value is NSNumber ? "number" : value == nil ? "absent" : "other"
        return ["kind": kind, "knownBoolean": enabled != nil, "enabled": enabled == true]
    }

    func prepareRun() throws {
        continueAfterFailure = false
        executionTimeAllowance = 1200
        guard NSUserName() == "runner", NSHomeDirectory() == "/Users/runner",
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw ReadinessFailure("Release checks require a disposable hosted Mac")
        }
        addTeardownBlock { @MainActor [self] in
            var failure: Error?
            do { try cleanUpCandidate() } catch { failure = error }
            do { try audioDevices?.restore() } catch { failure = error }
            audioDevices = nil
            if let failure { throw failure }
        }
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        let key = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/openai-api-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: key.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, getuid())
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
        let devices = try ReleaseAudioDevices()
        audioDevices = devices
    }

    func launchInstalledApp() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JARVIS_READINESS_APP_PATH"], path.hasPrefix("/"),
              let expectedVersion = environment["JARVIS_READINESS_EXPECTED_VERSION"], !expectedVersion.isEmpty else {
            throw ReadinessFailure("Required installed app path and expected version are missing")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(url.pathExtension, "app")
        XCTAssertEqual(bundle.bundleIdentifier, bundleID)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, expectedVersion)
        XCTAssertNotEqual(bundle.object(forInfoDictionaryKey: "JarvisDevelopmentBuild") as? Bool, true)
        installedURL = url
        let app = XCUIApplication(url: url)
        app.launchArguments = []
        app.launchEnvironment = [:]
        application = app
        app.launch()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        XCTAssertEqual(running.count, 1, "Exactly one installed candidate must run")
        let actual = try XCTUnwrap(running.first)
        XCTAssertEqual(actual.bundleURL?.resolvingSymlinksInPath(), url)
        #if arch(arm64)
        let expectedArchitecture = NSBundleExecutableArchitectureARM64
        let architectureName = "arm64"
        #elseif arch(x86_64)
        let expectedArchitecture = NSBundleExecutableArchitectureX86_64
        let architectureName = "x86_64"
        #else
        #error("Release ready check requires a supported native Mac architecture")
        #endif
        XCTAssertEqual(actual.executableArchitecture, expectedArchitecture,
                       "The installed candidate must execute the runner's native architecture")
        let identity = "path=\(url.path)\nversion=\(expectedVersion)\npid=\(actual.processIdentifier)\narchitecture=\(architectureName)\nexecutingArchitecture=\(actual.executableArchitecture)\n"
        let attachment = XCTAttachment(string: identity)
        attachment.name = "installed-process-identity"
        attachment.lifetime = .keepAlways
        add(attachment)
        return app
    }

    func attachEvidence(_ app: XCUIApplication? = nil, name: String) {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else {
            XCTFail("Required private evidence directory is missing")
            return
        }
        do {
            let receipt: [String: Any] = ["stage": name, "appState": app?.state.rawValue ?? 0,
                                         "uptime": ProcessInfo.processInfo.systemUptime]
            let data = try JSONSerialization.data(withJSONObject: receipt)
            try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("ui-stage.json"), options: .atomic)
            let progressURL = URL(fileURLWithPath: path).appendingPathComponent("ui-progress.json")
            var progress: [[String: Any]] = []
            if FileManager.default.fileExists(atPath: progressURL.path) {
                progress = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: progressURL)) as? [[String: Any]])
            }
            guard progress.count < 64 else { throw ReadinessFailure("The bounded scalar UI progress record is full") }
            progress.append(receipt)
            try JSONSerialization.data(withJSONObject: progress).write(to: progressURL, options: .atomic)
        } catch {
            XCTFail("Could not record the scalar UI stage")
        }
    }

    private func cleanUpCandidate() throws {
        if let app = application {
            if app.state != .notRunning {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                if running.count == 1, running.first?.bundleURL?.resolvingSymlinksInPath() == installedURL {
                    app.terminate()
                    XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Candidate cleanup must finish")
                } else {
                    XCTFail("Cannot prove exact candidate ownership for cleanup")
                }
            }
        }
    }

    struct ReadinessFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
