import AppKit
import XCTest

extension ReleaseReadinessTests {
    func testInstalledJourney() throws {
        try prepareRun()
        let outputKind = try XCTUnwrap(audioDevices).outputKind.rawValue
        attachEvidence(name: "fixture-playback-default-route-\(outputKind)")
        try playQuestion()
        try audioDevices?.select()
        attachEvidence(name: "fixture-playback-selected-route")
        try playQuestion()
        let environment = ProcessInfo.processInfo.environment
        let phase = try XCTUnwrap(environment["JARVIS_READINESS_PHASE"])
        XCTAssertTrue(["fresh", "predecessor", "upgrade"].contains(phase))
        var app = try launchInstalledApp()
        let admitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows["Welcome to Jarvis"].exists || app.statusItems["Jarvis is stopped"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [admitted], timeout: 30), .completed)
        if app.windows["Welcome to Jarvis"].exists {
            XCTAssertNotEqual(phase, "upgrade", "An upgraded used profile must retain onboarding completion")
            app = try completePermissionOnboarding(app)
        }
        XCTAssertTrue(persistedOnboardingCompleted())
        XCTAssertTrue(app.statusItems["Jarvis is stopped"].exists)
        if phase == "upgrade" {
            let expectedPath = try XCTUnwrap(environment["JARVIS_READINESS_UPGRADE_PROFILE"])
            let expected = try XCTUnwrap(PropertyListSerialization.propertyList(
                from: Data(contentsOf: URL(fileURLWithPath: expectedPath)), format: nil) as? [String: Any])
            let actual = try preferences()
            for (key, value) in expected {
                XCTAssertTrue(NSDictionary(dictionary: [key: value]).isEqual(to: [key: actual[key] as Any]),
                              "Upgrade must retain existing user preferences before any setting changes")
            }
        }
        try checkSkills(app)
        try selectOpenAIBrain(app)
        let models = phase == "predecessor" ? ["GPT Transcribe"] : ["GPT Transcribe", "GPT-4o Transcribe"]
        var results: [[String: Any]] = []
        for model in models {
            try selectTranscription(model, app: app)
            for cycle in 1...(phase == "predecessor" ? 1 : 2) {
                results.append(try runSession(app, model: model, cycle: cycle))
            }
        }
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Normal Quit must close the exact installed app")
        try audioDevices?.restore()
        audioDevices = nil
        let receipt: [String: Any] = ["schemaVersion": 1, "phase": phase, "skills": 5,
                                     "nativeProcessVerified": true,
                                     "normalQuit": true, "defaultsRestored": true, "sessions": results]
        let evidence = try XCTUnwrap(environment["JARVIS_READINESS_EVIDENCE"])
        try JSONSerialization.data(withJSONObject: receipt).write(
            to: URL(fileURLWithPath: evidence).appendingPathComponent("journey.json"), options: .atomic)
    }

    private func settings(_ app: XCUIApplication) throws -> XCUIElement {
        let stopped = app.statusItems["Jarvis is stopped"]
        XCTAssertTrue(stopped.waitForExistence(timeout: 10))
        stopped.click()
        let item = app.menuItems["Settings"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        let window = app.windows["Jarvis Settings"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        let back = window.buttons["Back to Jarvis"]
        if back.exists { back.click() }
        return window
    }

    private func checkSkills(_ app: XCUIApplication) throws {
        attachEvidence(app, name: "journey-skills")
        let window = try settings(app)
        window.buttons["Skills"].click()
        for title in ["Behavioral", "Coding", "Coding with AI", "Customer scenario design", "System design"] {
            XCTAssertTrue(window.staticTexts[title].waitForExistence(timeout: 10))
            XCTAssertTrue(window.switches["\(title) skill"].exists)
        }
        XCTAssertFalse(window.staticTexts["No skills are installed."].exists)
        window.typeKey("w", modifierFlags: .command)
    }

    private func selectOpenAIBrain(_ app: XCUIApplication) throws {
        attachEvidence(app, name: "journey-brain")
        let window = try settings(app)
        window.buttons["Brain settings"].click()
        let provider = window.popUpButtons["Primary provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.click()
        app.menuItems["OpenAI API"].click()
        XCTAssertEqual(provider.value as? String, "OpenAI API")
        XCTAssertEqual(window.popUpButtons.matching(NSPredicate(format: "label BEGINSWITH 'Fallback '")).count, 0)
        window.typeKey("w", modifierFlags: .command)
    }

    private func selectTranscription(_ model: String, app: XCUIApplication) throws {
        attachEvidence(app, name: "journey-transcription")
        let window = try settings(app)
        window.buttons["Ear settings"].click()
        let provider = window.popUpButtons["Transcription provider"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.click()
        app.menuItems["OpenAI"].click()
        let picker = window.popUpButtons["OpenAI transcription model"]
        picker.click()
        app.menuItems[model].click()
        XCTAssertEqual(picker.value as? String, model)
        window.typeKey("w", modifierFlags: .command)
    }

    private func runSession(_ app: XCUIApplication, model: String, cycle: Int) throws -> [String: Any] {
        attachEvidence(app, name: "journey-start")
        _ = try candidateProcessID()
        try audioDevices?.verify()
        let previous = try sessionDirectories()
        let started = Date().timeIntervalSince1970
        app.statusItems["Jarvis is stopped"].click()
        app.menuItems["Start Jarvis"].click()
        XCTAssertTrue(app.statusItems["Jarvis is active"].waitForExistence(timeout: 60),
                      "Both endpoints and capture must reach full active readiness")
        attachEvidence(app, name: "journey-active")
        try audioDevices?.verify()
        let fresh = try sessionDirectories().subtracting(previous)
        XCTAssertEqual(fresh.count, 1, "Start must create one fresh production session")
        let directory = try XCTUnwrap(fresh.first)
        attachEvidence(app, name: "journey-transcript")
        try playQuestion()
        try waitUntil("The fixed system question must produce a fresh finalized transcript", timeout: 60) {
            guard let rows = try? self.activity(directory) else { return false }
            return rows.contains { row in
                let text = row.message.lowercased()
                return row.kind == "heard" && row.time >= started && text.hasPrefix("🗣 heard (them):")
                    && text.contains("binary search") && text.contains("sorted list")
            }
        }
        try audioDevices?.verify()
        let boundary = try activity(directory).map(\.order).max() ?? -1
        let shortcutAt = Date().timeIntervalSince1970
        attachEvidence(app, name: "journey-hint")
        app.typeKey("j", modifierFlags: [.command, .option])
        try waitUntil("The normal Hint shortcut must produce a fresh delivered hint", timeout: 90) {
            guard let rows = try? self.activity(directory),
                  let request = rows.first(where: { $0.kind == "manualHint" && $0.order > boundary && $0.time >= shortcutAt }) else {
                return false
            }
            return rows.contains { $0.kind == "tip" && $0.order > request.order && $0.time >= request.time
                && !($0.hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        XCTAssertTrue(app.statusItems["Jarvis is active"].exists)
        app.statusItems["Jarvis is active"].click()
        app.menuItems["Stop Jarvis"].click()
        XCTAssertTrue(app.statusItems["Jarvis is stopped"].waitForExistence(timeout: 30))
        try waitUntil("Stop must seal a complete production session", timeout: 30) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("audit-health.json")),
                  let health = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  health["state"] as? String == "complete", let rows = try? self.activity(directory) else { return false }
            return rows.contains { $0.kind == "sessionEnded" }
        }
        try audioDevices?.verify()
        attachEvidence(app, name: "\(model)-cycle-\(cycle)-complete")
        return ["model": model, "cycle": cycle, "fullActive": true, "freshSession": true,
                "stimulusTranscript": true, "shortcutHint": true, "stopped": true, "auditComplete": true]
    }

    private func playQuestion() throws {
        let environment = ProcessInfo.processInfo.environment
        let player = Process()
        player.executableURL = URL(fileURLWithPath: try XCTUnwrap(environment["JARVIS_READINESS_PLAYER"]))
        player.arguments = [try XCTUnwrap(environment["JARVIS_READINESS_SPEECH_FILE"])]
        player.environment = [:]
        player.standardOutput = FileHandle.nullDevice
        player.standardError = FileHandle.nullDevice
        defer { if player.isRunning { player.terminate() } }
        try player.run() // ghost-mode-allowed: external runner plays the fixed fixture through the hosted system output
        try waitUntil("The fixed question must finish playback", timeout: 30) { !player.isRunning }
        XCTAssertEqual(player.terminationReason, .exit)
        XCTAssertEqual(player.terminationStatus, 0, "The system player must finish successfully")
    }

    private struct Row: Decodable {
        let kind: String?
        let message: String
        let order: Int
        let time: TimeInterval
        let response: Response?
        var hint: String? { response?.hint }
        struct Response: Decodable { let hint: String }
        enum CodingKeys: String, CodingKey { case kind = "k", message = "m", order = "q", time = "o", response }
    }

    private func activity(_ directory: URL) throws -> [Row] {
        let file = directory.appendingPathComponent("jarvis-activity.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8_388_608 else {
            throw ReadinessFailure("Session evidence exceeds the bounded fixture size")
        }
        let data = try Data(contentsOf: file)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        return try lines.filter { !$0.isEmpty }.map { try JSONDecoder().decode(Row.self, from: Data($0)) }
    }

    private func sessionDirectories() throws -> Set<URL> {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Jarvis/sessions")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true })
    }

    private func preferences() throws -> [String: Any] {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any])
    }

    private func waitUntil(_ message: String, timeout: TimeInterval, _ condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }
}
