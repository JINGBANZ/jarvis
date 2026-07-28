import Testing
import Foundation
@testable import JarvisCore

@Suite struct ActivityLogTests {
    @Test func cssClassKeysOnLeadingMarker() {
        #expect(ActivityLog.cssClass(for: "💬 use a hash map") == "say")
        #expect(ActivityLog.cssClass(for: "👁 looking at your screen") == "see")
        #expect(ActivityLog.cssClass(for: "🗣 heard: \"hello\"") == "hear")
        #expect(ActivityLog.cssClass(for: "🤫 quiet for 8s") == "hear")
        #expect(ActivityLog.cssClass(for: "🤫 stayed silent — nothing useful to add") == "think")
        #expect(ActivityLog.cssClass(for: "💭 thinking…") == "think")
        #expect(ActivityLog.cssClass(for: "… nothing useful to add, staying silent") == "think")
        #expect(ActivityLog.cssClass(for: "🧠 brain switch applied — OpenAI API → Claude Code") == "think")
        #expect(ActivityLog.cssClass(for: "⏹ session ended by user") == "think")
        #expect(ActivityLog.cssClass(
            for: "⏹ session ended by error — check jarvis-debug.log") == "err")
        #expect(ActivityLog.cssClass(for: "Jarvis realtime error event: oops") == "err")
        #expect(ActivityLog.cssClass(for: "Jarvis: coaching started.") == "")
        // A spoken tip can legitimately contain "failed"; it must stay a 💬 say line.
        #expect(ActivityLog.cssClass(for: "💬 your test failed because the loop is off-by-one") == "say")
    }

    @Test func rowScriptEncodesTextSafelyAndOmitsImageWhenNil() throws {
        let js = ActivityLog.rowScript(time: "10:00:00", message: "a < b & \"c\" </script>", imageBase64: nil)
        #expect(js.hasPrefix("appendRow("))
        #expect(js.hasSuffix(");"))
        #expect(!js.contains("data:image"))            // no image payload when nil
        // The object inside appendRow(...) must be valid JSON with the raw (JSON-escaped) message.
        let inner = String(js.dropFirst("appendRow(".count).dropLast(");".count))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any])
        #expect(obj["message"] as? String == "a < b & \"c\" </script>")
        #expect(obj["time"] as? String == "10:00:00")
        #expect(obj["cls"] as? String == "")           // no leading marker
        #expect(obj["img"] == nil)                      // key omitted, not null
    }

    @Test func rowScriptBuildsDataURIWhenImagePresent() {
        let js = ActivityLog.rowScript(time: "10:00:01", message: "👁 looked", imageBase64: "QUJD")
        #expect(js.contains("data:image/jpeg;base64,QUJD"))
        #expect(js.contains("\"cls\":\"see\"") || js.contains("\"cls\": \"see\""))
    }

    @Test func recordPersistsJsonlAndShotThenNotifiesObserver() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        var pushed: [String] = []
        let snap = log.attach { pushed.append($0) }
        #expect(snap.rows.isEmpty)                       // empty session
        #expect(snap.total == 0)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        log.record(.screenViewed(imageBase64JPEG: pixel))
        log.record(.tip(lines: ["tip"]))
        _ = log.attach { _ in }                          // sync barrier: drains the serial queue

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.split(separator: "\n").count == 2)
        let shot = dir.appendingPathComponent("shot-1.jpg")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        #expect(pushed.count == 2)
        #expect(pushed[0].contains("data:image/jpeg;base64,"))
        #expect(pushed[1].contains("appendRow("))
    }

    @Test func flushPersistsEveryPreviouslyRecordedEvent() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)

        log.record(.sessionEnded(reason: .stoppedByUser))
        log.flush()

        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains(#""k":"sessionEnded""#)
            || jsonl.contains(#""k": "sessionEnded""#))
    }

    @Test func sessionEndMarkerRejectsLaterActivity() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)

        log.record(.tip(lines: ["before stop"]))
        log.record(.sessionEnded(reason: .stoppedByUser))
        log.record(.stayedSilent)
        log.flush()

        let snapshot = log.attach { _ in }
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("before stop"))
        #expect(snapshot.rows[1].contains("session ended by user"))
        #expect(!snapshot.rows.joined().contains("stayed silent"))
    }

    @Test func sessionBoundRecordCannotWriteIntoReplacementSession() throws {
        let old = Self.tmp()
        let replacement = Self.tmp()
        defer {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: replacement)
        }
        let log = ActivityLog()
        log.enable(directory: old)
        log.record(.tip(lines: ["old before rotation"]), sessionDirectory: old)
        log.enable(directory: replacement)

        log.record(.tip(lines: ["late old tip"]), sessionDirectory: old)
        log.record(.tip(lines: ["new tip"]), sessionDirectory: replacement)
        log.flush()

        let rows = log.attach { _ in }.rows
        #expect(rows.count == 1)
        #expect(rows[0].contains("new tip"))
        #expect(!rows[0].contains("late old tip"))
    }

    @Test func attachSnapshotReplaysExistingEntriesWithImageBytes() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        log.record(.screenViewed(imageBase64JPEG: pixel))
        log.record(.tip(lines: ["tip"]))
        let snap = log.attach { _ in }                   // late attach: snapshot must contain prior rows
        #expect(snap.rows.count == 2)
        #expect(snap.shown == 2)
        #expect(snap.total == 2)
        #expect(snap.rows[0].contains("data:image/jpeg;base64,"))   // image bytes re-read from disk
        #expect(snap.shellHTML.contains("appendRow"))               // shell carries the JS
    }

    @Test func enableCreatesJsonlImmediately() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        _ = log.attach { _ in }
        let url = dir.appendingPathComponent("jarvis-activity.jsonl")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func recordIsNoOpWhenDisabled() {
        let log = ActivityLog()                          // never enabled
        log.record(.tip(lines: ["should not crash or write anything"]))
        let snap = log.attach { _ in }
        #expect(snap.total == 0)
        #expect(snap.rows.isEmpty)
    }

    @Test func eventFormattingKeepsDiagnosticDetailsOut() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.heard(speaker: .them, text: "How would you optimize it?"))
        _ = log.attach { _ in }

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains(#"heard (them): \"How would you optimize it?\""#))
        #expect(!jsonl.contains("item"))
        #expect(!jsonl.contains("recovered"))
    }

    @Test func everyBrainActionHasAHumanFacingEvent() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.screenViewFailed)
        log.record(.stayedSilent)
        let snapshot = log.attach { _ in }

        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("couldn't view your screen"))
        #expect(snapshot.rows[0].contains("screen capture failed"))
        #expect(snapshot.rows[0].contains("Screen Recording permission"))
        #expect(snapshot.rows[1].contains("stayed silent"))
        #expect(ActivityLog.isHumanFacing(
            message: "👁 couldn't view your screen — screen capture failed; check Screen Recording permission",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "🤫 stayed silent — nothing useful to add",
            imageFile: nil
        ))
    }

    @Test func temporaryBrainFailureSaysListeningContinuesWithoutDiagnosticDetail() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.coachingTurnFailed(provider: .codexCLI))
        let snapshot = log.attach { _ in }

        let row = try #require(snapshot.rows.first)
        #expect(row.contains("Codex CLI couldn't respond this turn"))
        #expect(row.contains("listening continues"))
        #expect(!row.contains("timed out"))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ Codex CLI couldn't respond this turn — listening continues",
            imageFile: nil
        ))
        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        let persisted = try #require(try JSONSerialization.jsonObject(
            with: Data(jsonl.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(persisted["k"] as? String
            == ActivityLog.EventKind.coachingTurnFailed.rawValue)
    }

    @Test func brainChangeAppliedNamesProvidersWithoutDiagnosticDetail() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.brainChangeApplied(previous: .openAI, current: .claudeCode))
        let snapshot = log.attach { _ in }

        let row = try #require(snapshot.rows.first)
        #expect(row.contains("brain switch applied"))
        #expect(row.contains("OpenAI API"))
        #expect(row.contains("Claude Code"))
        #expect(!row.contains("OAuth"))
        #expect(!row.contains("token"))
        #expect(ActivityLog.isHumanFacing(
            message: "🧠 brain switch applied — OpenAI API → Claude Code",
            imageFile: nil
        ))
    }

    @Test func providerRouteLifecycleUsesFixedProviderOnlyCopy() throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog(); log.enable(directory: dir)
        log.record(.brainRouteAdvanced(previous: .openAI, current: .claudeCode))
        log.record(.brainRouteAdvanced(previous: .claudeCode, current: .claudeCode))
        log.record(.brainRouteTargetSkipped(provider: .codexCLI))
        let snapshot = log.attach { _ in }

        #expect(snapshot.rows.count == 3)
        #expect(snapshot.rows[0].contains(
            "OpenAI API couldn't respond — continuing on Claude Code"))
        #expect(snapshot.rows[1].contains(
            "Claude Code target couldn't respond — continuing with the next Claude Code model"))
        #expect(snapshot.rows[2].contains(
            "Codex CLI target is unavailable — skipping it"))
        #expect(!snapshot.rows.joined().contains("timeout"))
        #expect(!snapshot.rows.joined().contains("OAuth"))
        #expect(!snapshot.rows.joined().contains("token"))

        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        let kinds = try jsonl.split(separator: "\n").map { line in
            let value = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return value["k"] as? String
        }
        #expect(kinds == [
            ActivityLog.EventKind.brainRouteAdvanced.rawValue,
            ActivityLog.EventKind.brainRouteAdvanced.rawValue,
            ActivityLog.EventKind.brainRouteTargetSkipped.rawValue,
        ])
    }

    @Test func runtimeFailureNoticesStayFixedAndDiagnosticFree() {
        let events: [ActivityLog.Event] = [
            .sessionEnded(reason: .transcriptionStopped(reason: .connectionLost)),
            .sessionEnded(reason: .transcriptionStopped(reason: .quotaExceeded)),
            .sessionEnded(reason: .transcriptionStopped(reason: .authenticationFailed)),
            .sessionEnded(reason: .transcriptionStopped(reason: .accessDenied)),
            .sessionEnded(reason: .transcriptionStopped(reason: .configurationRejected)),
            .sessionEnded(reason: .audioCaptureUnavailable),
            .systemAudioStopped,
            .settingsChangeNotApplied,
        ]
        let messages = events.map { $0.rendered.message }

        #expect(messages.count == 8)
        #expect(messages[0].contains("session ended by error"))
        #expect(messages[0].contains("transcription connection was lost"))
        #expect(messages[1].contains("API quota is exhausted"))
        #expect(messages[1].contains("billing"))
        #expect(messages[2].contains("rejected the API key"))
        #expect(messages[3].contains("denied transcription access"))
        #expect(messages[4].contains("rejected the transcription configuration"))
        #expect(messages[5].contains("audio capture became unavailable"))
        #expect(messages[6].contains("microphone coaching continues"))
        #expect(messages[7].contains("current coaching session continues"))
        for message in messages {
            #expect(!message.contains("OAuth"))
            #expect(!message.contains("AirPods"))
            #expect(!message.contains("item_"))
        }
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ system audio stopped — microphone coaching continues; check jarvis-debug.log",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⏹ session ended by error — the OpenAI API quota is exhausted; check billing",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ settings change wasn't applied — current coaching session continues; check Settings → Brain",
            imageFile: nil
        ))
    }

    @Test func sessionEndReasonsAreExplicitSanitizedAndStable() {
        let reasons: [SessionEndReason] = [
            .stoppedByUser,
            .applicationQuit,
            .replacedByNewSession,
            .openAIAPIKeyMissing,
            .brainProviderNotConfigured,
            .brainRouteExhausted(lastProvider: .claudeCode),
            .transcriptionStopped(reason: .quotaExceeded),
            .audioCaptureUnavailable,
            .unexpectedError,
        ]
        let rendered = reasons.map { ActivityLog.Event.sessionEnded(reason: $0).rendered }
        let messages = rendered.map { $0.message }

        #expect(messages.count == reasons.count)
        #expect(messages[0].contains("session ended by user"))
        #expect(messages[1].contains("session ended because Jarvis quit"))
        #expect(messages[2].contains("session ended because a new session started"))
        #expect(messages[3].contains("API key is missing"))
        #expect(messages[4].contains("no Primary brain provider"))
        #expect(messages[5].contains("last target: Claude Code"))
        #expect(messages[6].contains("API quota is exhausted"))
        #expect(messages[7].contains("audio capture became unavailable"))
        #expect(messages[8].contains("check jarvis-debug.log"))
        #expect(!messages.joined().contains("OAuth"))
        #expect(!messages.joined().contains("AirPods"))
        #expect(!messages.joined().contains("item_"))
        #expect(rendered.map { $0.kind } == Array(
            repeating: ActivityLog.EventKind.sessionEnded,
            count: reasons.count
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⏹ session ended by user",
            imageFile: nil
        ))
    }

    /// Shared temp-dir helper (also used by SessionStoreTests). Owner-only dir, like the real app.
    static func tmp() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jarvis-test-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }
}
