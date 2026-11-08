import AppKit
import XCTest

@MainActor
final class ReleaseAcceptanceTests: XCTestCase {
    private let bundleID = "com.jarvis.coach"
    private var application: XCUIApplication?
    private var installedURL: URL?
    private var savedPreferences: [String: Any]?
    private var profilePrepared = false
    private var credentialFile: URL?

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
        window.buttons[XCUIIdentifierCloseWindow].click()
        app.activate()
        let applicationMenu = app.menuBars.menuBarItems["Jarvis"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 10))
        applicationMenu.click()
        let quit = applicationMenu.menuItems["Quit Jarvis"]
        XCTAssertTrue(quit.waitForExistence(timeout: 10))
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Quit must terminate the installed app")
    }

    func testPermissionOnboarding() throws {
        try prepareProfile(completed: false, placeholderCredential: true)
        let app = try launchInstalledApp()
        let welcome = app.windows["Welcome to Jarvis"]
        let grant = welcome.buttons["Grant Access"]
        XCTAssertTrue(grant.waitForExistence(timeout: 20), "Stored-key precondition must expose ordinary permission onboarding")
        attachEvidence(app, name: "permissions-before-grants")
        grant.click()
        var relaunched = false
        for permission in ["microphone", "audio", "screen"] {
            switch try permissionPrompt(for: permission, onboarding: welcome) {
            case .consent(let dialog):
                if permission == "screen", dialog.buttons.matching(identifier: "Open System Settings").count == 1 {
                    dialog.buttons["Open System Settings"].click()
                    relaunched = try grantScreenRecordingInSettings()
                } else {
                    let allow = consentButtons(in: dialog)
                    XCTAssertEqual(allow.count, 1, "Consent requires one unambiguous Allow control")
                    allow.element.click()
                }
            case .relaunch:
                let previous = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)
                welcome.buttons["Quit & Reopen"].click()
                let reopened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let running = NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID)
                    return running.count == 1 && running[0].processIdentifier != previous.processIdentifier
                        && running[0].bundleURL?.resolvingSymlinksInPath() == self.installedURL
                        && running[0].executableArchitecture == NSRunningApplication.current.executableArchitecture
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 15), .completed,
                               "Normal Quit & Reopen must replace the installed candidate process")
                relaunched = true
            }
        }
        app.activate()
        if welcome.buttons["Open System Settings"].waitForExistence(timeout: 5) {
            welcome.buttons["Open System Settings"].click()
            relaunched = try grantScreenRecordingInSettings() || relaunched
            app.activate()
        }
        if welcome.buttons["Quit & Reopen"].waitForExistence(timeout: 5) {
            welcome.buttons["Quit & Reopen"].click()
            relaunched = true
        }
        attachEvidence(app, name: "permissions-after-grants")
        let ready = welcome.buttons["I’m Ready"]
        let readyExists = ready.waitForExistence(timeout: relaunched ? 5 : 30)
        if !relaunched { XCTAssertTrue(readyExists, "Every grant must reach the ordinary I’m Ready action") }
        if readyExists { ready.click() }
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

    private enum PermissionPrompt {
        case consent(XCUIElement)
        case relaunch
    }

    private func permissionPrompt(for permission: String, onboarding: XCUIElement) throws -> PermissionPrompt {
        let owners = ["com.apple.UserNotificationCenter", "com.apple.coreservices.uiagent"]
        var captured: Set<String> = []
        var found: (String, XCUIElement)?
        var needsRelaunch = false
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            var matches: [(String, XCUIElement)] = []
            for identifier in owners where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                let candidate = XCUIApplication(bundleIdentifier: identifier)
                if captured.insert(identifier).inserted {
                    self.attachEvidence(candidate, name: "\(permission)-owner-first-\(identifier)")
                }
                let dialogs = candidate.dialogs.allElementsBoundByIndex
                let containers = dialogs.isEmpty ? candidate.windows.allElementsBoundByIndex : dialogs
                for container in containers {
                    let text = container.staticTexts.allElementsBoundByIndex.map {
                        $0.label + " " + ($0.value as? String ?? "")
                    }.joined(separator: "\n")
                    guard text.localizedCaseInsensitiveContains("Jarvis"),
                          text.localizedCaseInsensitiveContains(permission) else { continue }
                    let allow = self.consentButtons(in: container)
                    let opensSettings = permission == "screen" && container.buttons.matching(identifier: "Open System Settings").count == 1
                    if allow.count == 1 || opensSettings { matches.append((identifier, container)) }
                }
            }
            if matches.count == 1 {
                found = matches[0]
                return true
            }
            if matches.isEmpty, permission == "screen",
               onboarding.staticTexts.matching(NSPredicate(format: "value == 'Granted' OR label == 'Granted'")).count == 2,
               onboarding.staticTexts["Screen Recording"].exists,
               onboarding.staticTexts["Reopen to finish"].exists,
               onboarding.buttons["Quit & Reopen"].exists {
                needsRelaunch = true
                return true
            }
            return false
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 20)
        attachRunningApplicationInventory()
        for identifier in owners where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            let candidate = XCUIApplication(bundleIdentifier: identifier)
            print("permission=\(permission) owner=\(identifier) dialogs=\(candidate.dialogs.count) windows=\(candidate.windows.count)")
            attachEvidence(candidate, name: "\(permission)-owner-final-\(identifier)")
        }
        guard result == .completed else {
            throw AcceptanceFailure("No unique system dialog identified Jarvis and the expected \(permission) permission")
        }
        if needsRelaunch {
            let attachment = XCTAttachment(string: onboarding.debugDescription)
            attachment.name = "screen-recording-requires-normal-relaunch"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("permission=screen normalAction=Quit & Reopen; microphone/audio Granted, screen Reopen to finish")
            return .relaunch
        }
        let (identifier, dialog) = try XCTUnwrap(found)
        let attachment = XCTAttachment(string: dialog.debugDescription)
        attachment.name = "\(permission)-consent-container-\(identifier)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let text = dialog.staticTexts.allElementsBoundByIndex.map {
            $0.label + " " + ($0.value as? String ?? "")
        }.joined(separator: "\n")
        print("permission=\(permission) owner=\(identifier) type=\(dialog.elementType.rawValue) matchedText=\(String(text.prefix(1500)))")
        return .consent(dialog)
    }

    private func consentButtons(in dialog: XCUIElement) -> XCUIElementQuery {
        dialog.buttons.matching(NSPredicate(format:
            "label BEGINSWITH[c] 'Allow' OR title BEGINSWITH[c] 'Allow' OR label == 'OK' OR title == 'OK'"))
    }

    private func attachRunningApplicationInventory() {
        let identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).sorted()
        let attachment = XCTAttachment(string: identifiers.joined(separator: "\n"))
        attachment.name = "permission-running-application-identifiers"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func grantScreenRecordingInSettings() throws -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "Permission action must open System Settings")
        attachEvidence(settings, name: "system-screen-recording-settings")
        let toggle = settings.switches["Jarvis"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "System Settings must expose the candidate's recording toggle")
        if toggle.value as? String != "1" { toggle.click() }
        let confirm = settings.buttons["Quit & Reopen"]
        let relaunches = confirm.waitForExistence(timeout: 5)
        if relaunches { confirm.click() }
        XCTAssertEqual(toggle.value as? String, "1", "Screen-recording grant must be enabled")
        return relaunches
    }

    private func prepareProfile(completed: Bool, placeholderCredential: Bool = false) throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        addTeardownBlock { @MainActor [self] in try cleanUpCandidateAndProfile() }
        let username = NSUserName()
        let home = NSHomeDirectory()
        let githubActions = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"
        guard username == "runner", home == "/Users/runner", githubActions else {
            let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
            throw AcceptanceFailure("Profile-mutating release acceptance requires the disposable GitHub-hosted runner account; username=\(username), resolvedHome=\(resolvedHome), GITHUB_ACTIONS=\(githubActions)")
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
                contents: Data("release-acceptance-placeholder-not-a-credential".utf8),
                attributes: [.posixPermissions: 0o600]) else {
                throw AcceptanceFailure("Couldn't create the owner-only placeholder precondition")
            }
            credentialFile = file
        }
    }

    private func launchInstalledApp() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["JARVIS_ACCEPTANCE_APP_PATH"], path.hasPrefix("/"),
              let expectedVersion = environment["JARVIS_ACCEPTANCE_EXPECTED_VERSION"], !expectedVersion.isEmpty else {
            throw AcceptanceFailure("Required installed app path and expected version are missing")
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
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func cleanUpCandidateAndProfile() throws {
        if let app = application {
            if app.state != .notRunning {
                attachEvidence(app, name: "final-ui-state")
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

    private struct AcceptanceFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
