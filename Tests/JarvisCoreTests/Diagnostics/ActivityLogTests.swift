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

    @Test func recordPersistsJsonlAndShotThenNotifiesObserver() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        let pushedLock = NSLock()
        var pushedRows: [String] = []
        let snap = log.attach { row in pushedLock.withLock { pushedRows.append(row) } }
        #expect(snap.rows.isEmpty)                       // empty session
        #expect(snap.total == 0)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        evidence.record(.screenViewed(imageBase64JPEG: pixel))
        evidence.record(.tip(lines: ["tip"]))
        _ = await evidence.close()                       // barrier: drains the evidence worker

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.split(separator: "\n").count == 2)
        let shot = dir.appendingPathComponent("shot-1.jpg")
        #expect(FileManager.default.fileExists(atPath: shot.path))
        let perms = try FileManager.default.attributesOfItem(atPath: shot.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        let pushed = pushedLock.withLock { pushedRows }
        #expect(pushed.count == 2)
        #expect(pushed[0].contains("data:image/jpeg;base64,"))
        #expect(pushed[1].contains("appendRow("))
    }

    @Test func closingTheHandlePersistsEveryPreviouslyRecordedEvent() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)

        evidence.record(.sessionEnded(reason: .stoppedByUser))
        _ = await evidence.close()

        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        #expect(jsonl.contains(#""k":"sessionEnded""#)
            || jsonl.contains(#""k": "sessionEnded""#))
    }

    @Test func sessionEndMarkerRejectsLaterActivity() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)

        evidence.record(.tip(lines: ["before stop"]))
        evidence.record(.sessionEnded(reason: .stoppedByUser))
        evidence.record(.stayedSilent)
        _ = await evidence.close()

        _ = await evidence.close()
        let snapshot = log.attach { _ in }
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("before stop"))
        #expect(snapshot.rows[1].contains("session ended by user"))
        #expect(!snapshot.rows.joined().contains("stayed silent"))
    }

    @Test func attachSnapshotReplaysExistingEntriesWithImageBytes() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        let pixel = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        evidence.record(.screenViewed(imageBase64JPEG: pixel))
        evidence.record(.tip(lines: ["tip"]))
        _ = await evidence.close()
        let snap = log.attach { _ in }                   // late attach: snapshot must contain prior rows
        #expect(snap.rows.count == 2)
        #expect(snap.shown == 2)
        #expect(snap.total == 2)
        #expect(snap.rows[0].contains("data:image/jpeg;base64,"))   // image bytes re-read from disk
        #expect(snap.shellHTML.contains("appendRow"))               // shell carries the JS
    }

    /// The empty owner-only file exists before the first row so `SessionStore.listSessions()`
    /// can discover the session. The evidence worker creates it when it opens the session.
    @Test func openingTheSessionCreatesJsonlImmediately() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (_, evidence) = ActivityLog.recordingSession(in: dir)
        _ = await evidence.close()
        let url = dir.appendingPathComponent("jarvis-activity.jsonl")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
    }

    @Test func recordIsNoOpWhenTheProjectionIsDisabled() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = ActivityLog()                          // never enabled
        let evidence = FileSessionAudit(
            directory: dir,
            worker: SessionAuditWorker(limits: .production, writer: SessionAuditFileWriter()),
            activity: log)
        evidence.record(.tip(lines: ["should not crash or write anything"]))
        _ = await evidence.close()
        let snap = log.attach { _ in }
        #expect(snap.total == 0)
        #expect(snap.rows.isEmpty)
    }

    @Test func eventFormattingKeepsDiagnosticDetailsOut() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.heard(speaker: .them, text: "How would you optimize it?"))
        _ = await evidence.close()

        let jsonl = try String(contentsOf: dir.appendingPathComponent("jarvis-activity.jsonl"), encoding: .utf8)
        #expect(jsonl.contains(#"heard (them): \"How would you optimize it?\""#))
        #expect(!jsonl.contains("item"))
        #expect(!jsonl.contains("recovered"))
    }

    @Test func heardRowsUseSpeechTimeInsteadOfTranscriptCompletionOrder() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        let liveRowsLock = NSLock()
        var liveRows: [String] = []
        _ = log.attach { row in
            liveRowsLock.withLock { liveRows.append(row) }
        }

        // The short reply finishes transcription first, but it was spoken after the question.
        evidence.record(
            .heard(speaker: .me, text: "Yep."),
            at: Date(timeIntervalSince1970: 20))
        evidence.record(
            .heard(speaker: .them, text: "Did you see the pop-up?"),
            at: Date(timeIntervalSince1970: 10))

        _ = await evidence.close()
        let pushedRows = liveRowsLock.withLock { liveRows }
        #expect(pushedRows.count == 2)
        #expect(pushedRows[1].contains("\"insertionIndex\":0"))

        let rows = log.attach { _ in }.rows
        #expect(rows.count == 2)
        #expect(rows[0].contains("heard (them)"))
        #expect(rows[1].contains("heard (me)"))

        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename),
            encoding: .utf8)
        let persisted = try jsonl.split(separator: "\n").map { raw in
            try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
        #expect(persisted.map { $0["o"] as? Double } == [20, 10])
        #expect(persisted.allSatisfy { $0["q"] != nil && $0["r"] != nil })
    }

    @Test func everyBrainActionHasAHumanFacingEvent() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.screenViewFailed)
        evidence.record(.stayedSilent)
        _ = await evidence.close()
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

    @Test func prepNotesSearchedRendersMatchCountAndCssClass() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.prepNotesSearched(query: "rate limiter", matchCount: 2))
        evidence.record(.prepNotesSearched(query: "quantum computing", matchCount: 0))
        _ = await evidence.close()
        let snapshot = log.attach { _ in }

        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].contains("checked prep notes for \\\"rate limiter\\\""))
        #expect(snapshot.rows[0].contains("found 2 matches"))
        #expect(snapshot.rows[1].contains("nothing relevant found"))
        #expect(ActivityLog.cssClass(for: "📎 checked prep notes for \"rate limiter\" — found 2 matches")
            == "think")
    }

    @Test func temporaryBrainFailureSaysRetryingWithoutDiagnosticDetail() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.coachingTurnFailed(provider: .codexCLI))
        _ = await evidence.close()
        let snapshot = log.attach { _ in }

        let row = try #require(snapshot.rows.first)
        #expect(row.contains("Codex CLI couldn't finish the response"))
        #expect(row.contains("retrying"))
        #expect(row.contains("listening continues"))
        #expect(!row.contains("timed out"))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ Codex CLI couldn't finish the response — retrying while listening continues",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ Codex CLI couldn't respond this turn — listening continues",
            imageFile: nil
        ))
        let jsonl = try String(
            contentsOf: dir.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        let persisted = try #require(try JSONSerialization.jsonObject(
            with: Data(jsonl.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(persisted["k"] as? String
            == ActivityEvent.Kind.coachingTurnFailed.rawValue)
    }

    @Test func brainChangeAppliedNamesProvidersWithoutDiagnosticDetail() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.brainChangeApplied(previous: .openAI, current: .claudeCode))
        _ = await evidence.close()
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

    @Test func providerRouteLifecycleUsesFixedProviderOnlyCopy() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.brainRouteAdvanced(previous: .openAI, current: .claudeCode))
        evidence.record(.brainRouteAdvanced(previous: .claudeCode, current: .claudeCode))
        evidence.record(.brainRouteTargetSkipped(provider: .codexCLI))
        _ = await evidence.close()
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
            ActivityEvent.Kind.brainRouteAdvanced.rawValue,
            ActivityEvent.Kind.brainRouteAdvanced.rawValue,
            ActivityEvent.Kind.brainRouteTargetSkipped.rawValue,
        ])
    }

    @Test func runtimeFailureNoticesStayFixedAndDiagnosticFree() {
        let events: [ActivityEvent] = [
            .sessionEnded(reason: .transcriptionStopped(reason: .connectionLost)),
            .sessionEnded(reason: .transcriptionStopped(reason: .quotaExceeded)),
            .sessionEnded(reason: .transcriptionStopped(reason: .authenticationFailed)),
            .sessionEnded(reason: .transcriptionStopped(reason: .accessDenied)),
            .sessionEnded(reason: .transcriptionStopped(reason: .configurationRejected)),
            .sessionEnded(reason: .transcriptionStopped(reason: .appleSpeechUnavailable)),
            .sessionEnded(reason: .audioCaptureUnavailable),
            .systemAudioStopped,
            .settingsChangeNotApplied,
        ]
        let messages = events.map { $0.rendered.message }

        #expect(messages.count == 9)
        #expect(messages[0].contains("session ended by error"))
        #expect(messages[0].contains("transcription connection was lost"))
        #expect(messages[1].contains("API quota is exhausted"))
        #expect(messages[1].contains("billing"))
        #expect(messages[2].contains("rejected the API key"))
        #expect(messages[2].contains("Settings → Connections"))
        #expect(messages[3].contains("denied transcription access"))
        #expect(messages[4].contains("rejected the transcription configuration"))
        #expect(messages[5].contains("Apple Speech transcription became unavailable"))
        #expect(messages[6].contains("audio capture became unavailable"))
        #expect(messages[7].contains("microphone coaching continues"))
        #expect(messages[8].contains("current coaching session continues"))
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
            .permissionsMissing,
            .brainRouteExhausted(lastProvider: .claudeCode),
            .transcriptionStopped(reason: .quotaExceeded),
            .audioCaptureUnavailable,
            .unexpectedError,
        ]
        let rendered = reasons.map { ActivityEvent.sessionEnded(reason: $0).rendered }
        let messages = rendered.map { $0.message }

        #expect(messages.count == reasons.count)
        #expect(messages[0].contains("session ended by user"))
        #expect(messages[1].contains("session ended because Jarvis quit"))
        #expect(messages[2].contains("session ended because a new session started"))
        #expect(messages[3].contains("API key is missing"))
        #expect(messages[3].contains("Settings → Connections"))
        #expect(messages[4].contains("required permission is missing"))
        #expect(messages[5].contains("last target: Claude Code"))
        #expect(messages[6].contains("API quota is exhausted"))
        #expect(messages[7].contains("audio capture became unavailable"))
        #expect(messages[8].contains("check jarvis-debug.log"))
        #expect(!messages.joined().contains("OAuth"))
        #expect(!messages.joined().contains("AirPods"))
        #expect(!messages.joined().contains("item_"))
        #expect(rendered.map { $0.kind } == Array(
            repeating: ActivityEvent.Kind.sessionEnded,
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
