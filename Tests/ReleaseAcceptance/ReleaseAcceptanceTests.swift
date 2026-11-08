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
        status.click()
        let quit = status.menuItems["Quit Jarvis"]
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
        let permissions = ["microphone", "audio", "screen"]
        var accepted: [String] = []
        var openedScreenSettings = false
        let monitor = addUIInterruptionMonitor(withDescription: "Jarvis permission consent") { element in
            let description = element.debugDescription
            let attachment = XCTAttachment(string: description)
            attachment.name = "permission-interruption-\(accepted.count)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            self.attachRunningApplicationInventory()
            guard accepted.count < permissions.count else {
                XCTFail("Unexpected additional permission interruption")
                return false
            }
            let permission = permissions[accepted.count]
            guard description.localizedCaseInsensitiveContains("Jarvis"),
                  description.localizedCaseInsensitiveContains(permission) else {
                XCTFail("Refuse a dialog that does not identify Jarvis and the expected \(permission) permission")
                return false
            }
            if permission == "screen", element.buttons["Open System Settings"].exists {
                element.buttons["Open System Settings"].click()
                openedScreenSettings = true
            } else {
                let allow = element.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow' OR label == 'OK'")).firstMatch
                guard allow.exists else {
                    XCTFail("Permission dialog requires a supported Allow control: \(permission)")
                    return false
                }
                allow.click()
            }
            accepted.append(permission)
            return true
        }
        defer { removeUIInterruptionMonitor(monitor) }
        grant.click()
        var relaunched = false
        for permission in permissions where !accepted.contains(permission) {
            let blocked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                accepted.contains(permission) || !welcome.isEnabled
            }, object: nil)
            guard XCTWaiter.wait(for: [blocked], timeout: 15) == .completed else {
                attachRunningApplicationInventory()
                throw AcceptanceFailure("Expected macOS \(permission) consent did not interrupt onboarding")
            }
            if !accepted.contains(permission) {
                // XCTest invokes interruption handlers only while attempting an ordinary UI interaction.
                welcome.staticTexts["Hi, I’m Jarvis."].click()
            }
            let consent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                accepted.contains(permission)
            }, object: nil)
            guard XCTWaiter.wait(for: [consent], timeout: 15) == .completed else {
                attachRunningApplicationInventory()
                throw AcceptanceFailure("No validated macOS \(permission) consent was accepted")
            }
        }
        XCTAssertEqual(accepted, permissions, "Every required permission must have a validated consent action")
        if openedScreenSettings {
            XCUIApplication(bundleIdentifier: "com.apple.systempreferences").activate()
            relaunched = try grantScreenRecordingInSettings()
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
        let identity = "path=\(url.path)\nversion=\(expectedVersion)\npid=\(actual.processIdentifier)\n"
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

    override func tearDown() async throws {
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
        try await super.tearDown()
    }

    private struct AcceptanceFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
