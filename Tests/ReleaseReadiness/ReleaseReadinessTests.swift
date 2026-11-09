import AppKit
import XCTest

@MainActor
final class ReleaseReadinessTests: XCTestCase {
    private let bundleID = "com.jarvis.coach"
    private var application: XCUIApplication?
    private var installedURL: URL?
    private var savedPreferences: [String: Any]?
    private var profilePrepared = false
    private var credentialFile: URL?

    override func record(_ issue: XCTIssue) {
        if let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] {
            let location = issue.sourceCodeContext.location
            let ownSource = location?.fileURL.lastPathComponent == "ReleaseReadinessTests.swift"
            let receipt: [String: Any] = ["issueType": issue.type.rawValue,
                                          "sourceIsHarness": ownSource,
                                          "line": ownSource ? location?.lineNumber ?? 0 : 0]
            do {
                let data = try JSONSerialization.data(withJSONObject: receipt)
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("ui-issue.json"), options: .withoutOverwriting)
            } catch CocoaError.fileWriteFileExists {
            } catch {
                print("Could not record the scalar UI issue location")
            }
        }
        super.record(issue)
    }

    func testFreshOnboarding() throws {
        try prepareProfile(completed: false)
        let app = try launchInstalledApp()
        let welcome = app.windows["Welcome to Jarvis"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 20), "Normal fresh launch must show onboarding")
        XCTAssertTrue(welcome.secureTextFields["OpenAI API key"].exists)
        XCTAssertTrue(welcome.staticTexts["Hi, I’m Jarvis."].exists)
        attachEvidence(app, name: "fresh-onboarding")
    }

    func testConfiguredSettingsAndSkills() throws {
        try prepareProfile(completed: true)
        let app = try launchInstalledApp()
        let status = app.statusItems["Jarvis is stopped"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "Normal launch must create the stopped status item")
        status.click()
        let settings = app.menuItems["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(app.menuItems["Start Jarvis"].exists)
        settings.click()
        let window = app.windows["Jarvis Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["Skills"].click()
        let titles = ["Behavioral", "Coding", "Coding with AI", "Customer scenario design", "System design"]
        for title in titles {
            XCTAssertTrue(window.staticTexts[title].waitForExistence(timeout: 10), "Missing installed skill: \(title)")
            XCTAssertTrue(window.switches["\(title) skill"].exists, "Missing skill control: \(title)")
        }
        XCTAssertFalse(window.staticTexts["No skills are installed."].exists)
        attachEvidence(app, name: "installed-skills")
        window.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Quit must terminate the installed app")
    }

    func testPermissionOnboarding() throws {
        try prepareProfile(completed: false, placeholderCredential: true)
        let app = try launchInstalledApp()
        let welcome = app.windows["Welcome to Jarvis"]
        let grant = welcome.buttons["Grant Access"]
        XCTAssertTrue(grant.waitForExistence(timeout: 20), "Stored-key precondition must expose ordinary permission onboarding")
        attachEvidence(app, name: "permissions-before-grants")
        recordPermissionState(onboarding: welcome, acceptedConsents: [], reason: .initial)
        var grantProcesses: Set<pid_t> = []
        var acceptedConsents: Set<String> = []
        var reachedReady = false
        for step in 1...12 {
            switch try nextPermissionAction(onboarding: welcome, acceptedConsents: acceptedConsents) {
            case .consent(let permissions, let dialog):
                acceptedConsents.formUnion(permissions)
                if permissions.contains("screen"), dialog.buttons.matching(identifier: "Open System Settings").count == 1 {
                    let previousPID = try candidateProcessID()
                    dialog.buttons["Open System Settings"].click()
                    if try grantScreenRecordingInSettings() { waitForReplacement(of: previousPID) }
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
                    XCTAssertTrue(welcome.staticTexts["Screen Recording"].exists)
                    let previousPID = try candidateProcessID()
                    welcome.buttons[title].click()
                    if try grantScreenRecordingInSettings() { waitForReplacement(of: previousPID) }
                    app.activate()
                case "Quit & Reopen":
                    XCTAssertEqual(grantedPermissionCount(in: welcome), 2,
                                   "Relaunch requires microphone and system audio proof")
                    XCTAssertEqual(welcome.staticTexts.matching(identifier: "Reopen to finish").count, 1,
                                   "The ordinary relaunch must be offered for the pending screen grant")
                    let previousPID = try candidateProcessID()
                    welcome.buttons[title].click()
                    waitForReplacement(of: previousPID)
                    app.activate()
                case "I’m Ready":
                    XCTAssertEqual(grantedPermissionCount(in: welcome), 3, "Every permission must be positively granted")
                    XCTAssertTrue(acceptedConsents.contains("microphone"), "Fresh acceptance must grant native microphone consent")
                    XCTAssertTrue(acceptedConsents.contains("audio"), "Fresh acceptance must grant native system-audio consent")
                    XCTAssertTrue(acceptedConsents.contains("screen"), "Fresh acceptance must observe native screen-recording consent")
                    welcome.buttons[title].click()
                    reachedReady = true
                default:
                    throw ReadinessFailure("Unexpected permission action: \(title)")
                }
            }
            if reachedReady { break }
        }
        XCTAssertTrue(reachedReady, "The bounded permission journey must reach and use the ordinary I’m Ready action")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: welcome)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed,
                       "Permission onboarding must actually close")
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(bundleID).plist")
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let data = try? Data(contentsOf: preferencesURL),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return values["onboarding.completed"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 15), .completed,
                       "Normal onboarding must persist completion; read the actual preference file afresh")
        XCTAssertTrue(app.statusItems["Jarvis is stopped"].waitForExistence(timeout: 30),
                      "Normal onboarding must prove every grant before entering the stopped app")
    }

    private enum PermissionAction {
        case consent(Set<String>, XCUIElement)
        case onboarding(String)
    }

    private func nextPermissionAction(onboarding: XCUIElement, acceptedConsents: Set<String>) throws -> PermissionAction {
        let owners = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent",
                      "com.apple.accessibility.universalAccessAuthWarn"]
        var captured: Set<String> = []
        var action: PermissionAction?
        var consentOwner: String?
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            var matches: [(String, Set<String>, XCUIElement)] = []
            var hasConsentPrompt = false
            var discovery: [String: [String: Int]] = [:]
            for identifier in owners {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count
                var counts = ["running": running, "dialogs": 0, "containers": 0, "jarvisTextMatches": 0,
                              "fixtureTextMatches": 0,
                              "jarvisLabelMatches": 0, "jarvisTitleMatches": 0, "jarvisStaticTextMatches": 0,
                              "microphoneMatches": 0, "audioMatches": 0, "screenMatches": 0,
                              "allowButtons": 0, "openSettingsButtons": 0]
                discovery[identifier] = counts
                guard running > 0 else { continue }
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
                    hasConsentPrompt = true
                    let allow = self.consentButtons(in: container)
                    counts["allowButtons", default: 0] += allow.count
                    counts["openSettingsButtons", default: 0] += container.buttons.matching(identifier: "Open System Settings").count
                    let opensSettings = permissions.contains("screen")
                        && container.buttons.matching(identifier: "Open System Settings").count == 1
                    if allow.count == 1 || opensSettings { matches.append((identifier, permissions, container)) }
                }
                discovery[identifier] = counts
            }
            if let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] {
                do {
                    try JSONSerialization.data(withJSONObject: discovery).write(
                        to: URL(fileURLWithPath: path).appendingPathComponent("permission-discovery.json"), options: .atomic)
                } catch { XCTFail("Could not record scalar native-dialog discovery") }
            }
            if matches.count == 1 {
                let (owner, permissions, dialog) = matches[0]
                action = .consent(permissions, dialog)
                consentOwner = owner
                return true
            }
            guard matches.isEmpty, !hasConsentPrompt else { return false }
            let titles = ["Grant Access", "Open System Settings", "Quit & Reopen", "I’m Ready"].filter {
                let pendingScreenRelaunch = $0 == "Quit & Reopen" && self.grantedPermissionCount(in: onboarding) == 2
                    && onboarding.staticTexts.matching(identifier: "Reopen to finish").count == 1
                guard $0 == "Grant Access" || acceptedConsents.contains("screen") || pendingScreenRelaunch else { return false }
                let button = onboarding.buttons[$0]
                return button.exists && button.isEnabled
            }
            guard titles.count == 1 else { return false }
            action = .onboarding(titles[0])
            return true
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 20)
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

    private func grantedPermissionCount(in onboarding: XCUIElement) -> Int {
        onboarding.staticTexts.matching(NSPredicate(format: "value == 'Granted' OR label == 'Granted'")).count
    }

    private func candidateProcessID() throws -> pid_t {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        XCTAssertEqual(running.count, 1, "Exactly one installed candidate must run")
        let candidate = try XCTUnwrap(running.first)
        XCTAssertEqual(candidate.bundleURL?.resolvingSymlinksInPath(), installedURL)
        XCTAssertEqual(candidate.executableArchitecture, NSRunningApplication.current.executableArchitecture)
        return candidate.processIdentifier
    }

    private func waitForReplacement(of previousPID: pid_t) {
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID)
            return running.count == 1 && running[0].processIdentifier != previousPID
                && running[0].bundleURL?.resolvingSymlinksInPath() == self.installedURL
                && running[0].executableArchitecture == NSRunningApplication.current.executableArchitecture
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 15), .completed,
                       "Normal Quit & Reopen must replace the installed candidate process")
    }

    private func consentButtons(in dialog: XCUIElement) -> XCUIElementQuery {
        dialog.buttons.matching(NSPredicate(format:
            "label BEGINSWITH[c] 'Allow' OR title BEGINSWITH[c] 'Allow' OR label == 'OK' OR title == 'OK'"))
    }

    private func grantScreenRecordingInSettings() throws -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "Permission action must open System Settings")
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
        if toggle.value as? String != "1" { toggle.click() }
        let authorized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toggle.value as? String == "1" || settings.buttons["Quit & Reopen"].exists
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
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
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
        let evidence = try XCTUnwrap(ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"])
        try JSONSerialization.data(withJSONObject: finalState).write(
            to: URL(fileURLWithPath: evidence).appendingPathComponent("recording-final.json"), options: .atomic)
        XCTAssertEqual(enabledResult, .completed, "Screen-recording grant must be enabled")
        return relaunches
    }

    private func recordingToggleValue(_ value: Any?) -> [String: Any] {
        if let value = value as? String {
            return ["kind": "string", "knownBoolean": ["0", "1"].contains(value), "enabled": value == "1"]
        }
        if let value = value as? NSNumber {
            return ["kind": "number", "knownBoolean": value == 0 || value == 1, "enabled": value == 1]
        }
        return ["kind": value == nil ? "absent" : "other", "knownBoolean": false, "enabled": false]
    }

    private func prepareProfile(completed: Bool, placeholderCredential: Bool = false) throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        addTeardownBlock { @MainActor [self] in try cleanUpCandidateAndProfile() }
        let username = NSUserName()
        let home = NSHomeDirectory()
        let githubActions = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        guard username == "runner", home == "/Users/runner", githubActions,
              ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
            throw ReadinessFailure("Profile-mutating release setup requires the disposable GitHub-hosted runner account; username=\(username), resolvedHome=\(resolvedHome), GITHUB_ACTIONS=\(githubActions)")
        }
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                      "Refuse to replace a pre-existing Jarvis process")
        let defaults = UserDefaults.standard
        savedPreferences = defaults.persistentDomain(forName: bundleID)
        defaults.removePersistentDomain(forName: bundleID)
        defaults.setPersistentDomain(["onboarding.completed": completed], forName: bundleID)
        defaults.synchronize()
        profilePrepared = true
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
        for name in ["openai-api-key", "gemini-api-key", "deepgram-api-key"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent(name).path),
                           "Credential-free acceptance refuses an existing credential")
        }
        if placeholderCredential {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = support.appendingPathComponent("openai-api-key")
            guard FileManager.default.createFile(atPath: file.path,
                contents: Data("release-readiness-placeholder-not-a-credential".utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw ReadinessFailure("Couldn't create the owner-only placeholder precondition")
            }
            credentialFile = file
        }
    }

    private func launchInstalledApp() throws -> XCUIApplication {
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
        #error("Release acceptance requires a supported native Mac architecture")
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

    private func attachEvidence(_ app: XCUIApplication, name: String) {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_READINESS_EVIDENCE"] else {
            XCTFail("Required private evidence directory is missing")
            return
        }
        do {
            let receipt: [String: Any] = ["stage": name, "appState": app.state.rawValue,
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

    private func cleanUpCandidateAndProfile() throws {
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
        if profilePrepared {
            let defaults = UserDefaults.standard
            if let savedPreferences { defaults.setPersistentDomain(savedPreferences, forName: bundleID) }
            else { defaults.removePersistentDomain(forName: bundleID) }
            defaults.synchronize()
        }
        if let credentialFile { try FileManager.default.removeItem(at: credentialFile) }
    }

    private struct ReadinessFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
