import AppKit
import Darwin
import XCTest

@MainActor
final class ReleaseAcceptanceTests: XCTestCase {
    private let bundleID = "com.jarvis.coach"
    private var application: XCUIApplication?
    private var installedURL: URL?
    private var savedPreferences: [String: Any]?
    private var profilePrepared = false
    private var credentialFile: URL?
    private var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?

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
                    throw AcceptanceFailure("Unexpected permission action: \(title)")
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
            for identifier in owners where !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                let candidate = XCUIApplication(bundleIdentifier: identifier)
                if captured.insert(identifier).inserted {
                    self.attachEvidence(candidate, name: "permission-owner-first-\(identifier)")
                }
                let dialogs = candidate.dialogs.allElementsBoundByIndex
                let containers = dialogs.isEmpty ? candidate.windows.allElementsBoundByIndex : dialogs
                for container in containers {
                    let text = container.staticTexts.allElementsBoundByIndex.map {
                        $0.label + " " + ($0.value as? String ?? "")
                    }.joined(separator: "\n")
                    guard text.localizedCaseInsensitiveContains("Jarvis") else { continue }
                    let permissions = Set(["microphone", "audio", "screen"].filter {
                        text.localizedCaseInsensitiveContains($0)
                    })
                    guard !permissions.isEmpty else { continue }
                    hasConsentPrompt = true
                    let allow = self.consentButtons(in: container)
                    let opensSettings = permissions.contains("screen")
                        && container.buttons.matching(identifier: "Open System Settings").count == 1
                    if allow.count == 1 || opensSettings { matches.append((identifier, permissions, container)) }
                }
            }
            if matches.count == 1 {
                let (owner, permissions, dialog) = matches[0]
                action = .consent(permissions, dialog)
                consentOwner = owner
                return true
            }
            guard matches.isEmpty, !hasConsentPrompt else { return false }
            let titles = ["Grant Access", "Open System Settings", "Quit & Reopen", "I’m Ready"].filter {
                guard $0 == "Grant Access" || acceptedConsents.contains("screen") else { return false }
                let button = onboarding.buttons[$0]
                return button.exists && button.isEnabled
            }
            guard titles.count == 1 else { return false }
            action = .onboarding(titles[0])
            return true
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 20)
        attachRunningApplicationInventory()
        guard result == .completed, let action else {
            throw AcceptanceFailure("No unique validated system consent or ordinary permission action became available")
        }
        if case .consent(let permissions, let dialog) = action {
            let owner = try XCTUnwrap(consentOwner)
            let attachment = XCTAttachment(string: dialog.debugDescription)
            attachment.name = "\(permissions.sorted().joined(separator: "-"))-consent-container-\(owner)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let text = dialog.staticTexts.allElementsBoundByIndex.map {
                $0.label + " " + ($0.value as? String ?? "")
            }.joined(separator: "\n")
            print("permissions=\(permissions.sorted()) owner=\(owner) type=\(dialog.elementType.rawValue) matchedText=\(String(text.prefix(1500)))")
        }
        return action
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

    private func attachRunningApplicationInventory() {
        let identifiers = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).sorted()
        let attachment = XCTAttachment(string: identifiers.joined(separator: "\n"))
        attachment.name = "permission-running-application-identifiers"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Permission UI application identifiers: \(String(identifiers.joined(separator: ", ").prefix(6000)))")
    }

    private func grantScreenRecordingInSettings() throws -> Bool {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.systempreferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15), "Permission action must open System Settings")
        attachEvidence(settings, name: "system-screen-recording-settings")
        let panes = settings.scrollViews.containing(.staticText, identifier: "Screen & System Audio Recording")
        XCTAssertTrue(panes.firstMatch.waitForExistence(timeout: 10), "The recording privacy pane must load")
        XCTAssertEqual(panes.count, 1, "The recording privacy pane must be unambiguous")
        let pane = panes.element
        let screenHeading = pane.staticTexts["Screen & System Audio Recording"]
        let audioOnlyHeading = pane.staticTexts["System Audio Recording Only"]
        XCTAssertTrue(audioOnlyHeading.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(screenHeading.frame.height, 0)
        XCTAssertGreaterThan(audioOnlyHeading.frame.minY, screenHeading.frame.maxY)
        let sections = pane.outlines.containing(.switch, identifier: "Jarvis_Toggle").allElementsBoundByIndex.filter {
            let frame = $0.frame
            return frame.height > 0 && frame.minY >= screenHeading.frame.maxY && frame.maxY <= audioOnlyHeading.frame.minY
        }
        XCTAssertEqual(sections.count, 1, "Exactly one Jarvis outline must belong to the screen-recording section")
        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(section.staticTexts["Jarvis_Title"].value as? String, "Jarvis")
        XCTAssertEqual(section.switches.matching(identifier: "Jarvis_Toggle").count, 1)
        let toggle = section.switches["Jarvis_Toggle"]
        if toggle.value as? String != "1" { toggle.click() }
        try authorizeRecordingSettings(settings, toggle: toggle)
        let confirm = settings.buttons["Quit & Reopen"]
        let relaunches = confirm.waitForExistence(timeout: 5)
        if relaunches { confirm.click() }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: toggle)
        let enabledResult = XCTWaiter.wait(for: [enabled], timeout: 5)
        let description = panes.count == 1 ? panes.element.debugDescription : settings.debugDescription
        print("System Settings recording controls:\n\(String(description.suffix(16000)))")
        attachEvidence(settings, name: "system-screen-recording-settings-final")
        XCTAssertEqual(enabledResult, .completed, "Screen-recording grant must be enabled")
        return relaunches
    }

    private func authorizeRecordingSettings(_ settings: XCUIApplication, toggle: XCUIElement) throws {
        let owner = "com.apple.LocalAuthenticationRemoteService"
        let agent = XCUIApplication(bundleIdentifier: owner)
        var dialog: XCUIElement?
        let authorization = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty {
                let dialogs = agent.dialogs.allElementsBoundByIndex
                let containers = dialogs.isEmpty ? agent.windows.allElementsBoundByIndex : dialogs
                let matches = containers.filter { container in
                    let text = container.staticTexts.allElementsBoundByIndex.map {
                        $0.label + " " + ($0.value as? String ?? "")
                    }.joined(separator: "\n")
                    return text.contains("Privacy & Security")
                        && text.localizedCaseInsensitiveContains("modify your system settings")
                        && container.textFields.count == 1 && container.secureTextFields.count == 1
                        && container.buttons.matching(identifier: "Modify Settings").count == 1
                }
                if matches.count == 1 { dialog = matches[0]; return true }
            }
            return toggle.value as? String == "1" || settings.buttons["Quit & Reopen"].exists
        }, object: nil)
        let result = XCTWaiter.wait(for: [authorization], timeout: 10)
        attachRunningApplicationInventory()
        if (dialog != nil || result != .completed),
           !NSRunningApplication.runningApplications(withBundleIdentifier: owner).isEmpty {
            attachEvidence(agent, name: "screen-recording-authorization-before-credentials")
            print("Screen-recording authorization UI:\n\(String(agent.debugDescription.prefix(12000)))")
        }
        guard result == .completed else { throw AcceptanceFailure("No recognized recording authorization result") }
        guard let dialog else { return }
        let credentials = try readAuthorizationCredential()
        let username = dialog.textFields.element
        username.click()
        username.typeKey("a", modifierFlags: .command)
        username.typeText(credentials.username)
        let password = dialog.secureTextFields.element
        password.click()
        password.typeKey("a", modifierFlags: .command)
        let pasteboard = NSPasteboard.general
        savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
        pasteboard.clearContents()
        guard pasteboard.setString(credentials.password, forType: .string) else {
            restoreClipboard()
            throw AcceptanceFailure("Could not prepare ephemeral authorization paste")
        }
        password.typeKey("v", modifierFlags: .command)
        restoreClipboard()
        dialog.buttons["Modify Settings"].click()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dialog)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "Native authorization must accept the temporary administrator")
    }

    private struct AuthorizationCredential: Decodable {
        let marker: String
        let username: String
        let password: String
        let uid: uid_t
        let owner_uid: uid_t
        let verified: Bool
    }

    private func readAuthorizationCredential() throws -> AuthorizationCredential {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              let temporary = environment["RUNNER_TEMP"], temporary.hasPrefix("/"),
              URL(fileURLWithPath: temporary).resolvingSymlinksInPath().path == temporary,
              environment["JARVIS_ACCEPTANCE_AUTH_FILE"] == temporary + "/jarvis-ui-authorization.json" else {
            throw AcceptanceFailure("Invalid hosted authorization location")
        }
        let directory = open(temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw AcceptanceFailure("Could not open hosted temporary directory") }
        defer { close(directory) }
        var directoryInfo = stat()
        guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o022 == 0 else { throw AcceptanceFailure("Unsafe hosted temporary directory") }
        let descriptor = openat(directory, "jarvis-ui-authorization.json", O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AcceptanceFailure("Missing ephemeral authorization file") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600,
              info.st_size > 0, info.st_size <= 4096 else { throw AcceptanceFailure("Unsafe ephemeral authorization file") }
        let credential: AuthorizationCredential
        do {
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 4097) ?? Data()
            guard data.count <= 4096 else { throw AcceptanceFailure("Oversized authorization file") }
            credential = try JSONDecoder().decode(AuthorizationCredential.self, from: data)
        } catch {
            throw AcceptanceFailure("Invalid ephemeral authorization file")
        }
        guard credential.marker == "jarvis-release-ui-authorization-v1", credential.username == "jarvisacceptance",
              credential.owner_uid == getuid(), credential.verified, credential.uid >= 501,
              credential.password.count >= 32, credential.password.count <= 128,
              let account = getpwnam(credential.username), account.pointee.pw_uid == credential.uid else {
            throw AcceptanceFailure("Unverified temporary authorization account")
        }
        return credential
    }

    private func restoreClipboard() {
        guard let savedClipboard else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = savedClipboard.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
        self.savedClipboard = nil
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
        restoreClipboard()
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
