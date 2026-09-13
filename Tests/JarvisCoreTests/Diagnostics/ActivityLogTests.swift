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
        let (_, evidence) = ActivityLog.recordingSession(in: dir)

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
        let (_, evidence) = ActivityLog.recordingSession(in: dir)
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

    /// The retry frame is fixed; the cause in front of it is the failure's own sentence, so a
    /// screenshot of Activity diagnoses a turn that failed for a reason nobody has classified yet.
    @Test func temporaryProviderFailureQuotesTheProviderInsideTheRetryFrame() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.coachingCycleFailed(failure: ProviderFailure(
            source: .brain(.codexCLI), stage: .process, category: .timeout,
            disposition: .temporary, identity: .init(transportDomain: "AgentRuntimeProcess"),
            message: "local agent runtime timed out after 60s")))
        _ = await evidence.close()
        let snapshot = log.attach { _ in }

        #expect(snapshot.rows.count == 1)
        let persisted = try Self.persistedRows(in: dir)
        #expect(persisted.count == 1)
        #expect(persisted[0].message == "⚠️ Codex CLI didn't respond in time "
            + "(local agent runtime timed out after 60s) — coaching failed; listening continues")
        #expect(persisted[0].kind == ActivityEvent.Kind.coachingCycleFailed.rawValue)
        #expect(ActivityLog.isHumanFacing(message: persisted[0].message, imageFile: nil))
        // Rows written before event kinds existed carry the two older wordings; the legacy filter
        // keys on the frame, so they stay visible alongside the sentence above.
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ Codex CLI couldn't finish the response — coaching cycle failed; listening continues",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ Codex CLI couldn't respond this turn — listening continues",
            imageFile: nil
        ))
    }

    /// A frame that says what Jarvis is doing about the failure puts the advice after it, so the
    /// row does not read as two instructions on either side of the dash. New rows carry a kind, so
    /// the legacy suffix filter (which the advice now follows) never has to judge one.
    @Test func adviceFollowsTheFrameRatherThanSplittingIt() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (_, evidence) = ActivityLog.recordingSession(in: dir)
        evidence.record(.coachingCycleFailed(failure: ProviderFailure(
            source: .brain(.openAI), stage: .connect, category: .unreachable,
            disposition: .temporary,
            identity: .init(transportDomain: NSURLErrorDomain, transportCode: -1009),
            message: "the internet connection appears to be offline")))
        evidence.record(.brainRouteTargetSkipped(failure: ProviderFailure(
            source: .brain(.claudeCode), stage: .process, category: .authentication,
            disposition: .permanent, identity: .init(), message: "")))
        _ = await evidence.close()

        let persisted = try Self.persistedRows(in: dir)
        #expect(persisted.count == 2)
        #expect(persisted[0].message
            == "\u{26A0}\u{FE0F} OpenAI API couldn't be reached for coaching "
            + "(network -1009: the internet connection appears to be offline) "
            + "\u{2014} coaching failed; listening continues; check your network or VPN")
        #expect(persisted[1].message
            == "\u{26A0}\u{FE0F} Claude Code isn't signed in \u{2014} skipping it; "
            + "sign in to the CLI and press Start again")
        for row in persisted {
            #expect(ActivityLog.isHumanFacing(
                message: row.message, imageFile: nil,
                kind: ActivityEvent.Kind(rawValue: row.kind ?? "")))
        }
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

    @Test func providerRouteLifecycleQuotesTheFailureInsideFixedFrames() async throws {
        let dir = Self.tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (log, evidence) = ActivityLog.recordingSession(in: dir)
        let rateLimited = ProviderFailure(
            source: .brain(.openAI), stage: .request, category: .rejected, disposition: .temporary,
            identity: .init(httpStatus: 429, errorCode: "rate_limit_exceeded"),
            message: "Rate limit reached")
        let missingCLI = ProviderFailure(
            source: .brain(.claudeCode), stage: .process, category: .unavailable,
            disposition: .permanent, identity: .init(), message: "Claude Code CLI was not found")
        evidence.record(.brainRouteAdvanced(
            previous: .openAI, current: .claudeCode, failure: rateLimited))
        evidence.record(.brainRouteAdvanced(
            previous: .openAI, current: .openAI, failure: rateLimited))
        evidence.record(.brainRouteTargetSkipped(failure: missingCLI))
        _ = await evidence.close()
        let snapshot = log.attach { _ in }

        #expect(snapshot.rows.count == 3)
        let persisted = try Self.persistedRows(in: dir)
        #expect(persisted.map(\.message) == [
            "⚠️ OpenAI API couldn't respond (HTTP 429, rate_limit_exceeded: Rate limit reached) — continuing on Claude Code",
            "⚠️ OpenAI API target couldn't respond (HTTP 429, rate_limit_exceeded: Rate limit reached) — continuing with the next OpenAI API model",
            "⚠️ Claude Code is unavailable (Claude Code CLI was not found) — skipping it",
        ])
        #expect(persisted.map(\.kind) == [
            ActivityEvent.Kind.brainRouteAdvanced.rawValue,
            ActivityEvent.Kind.brainRouteAdvanced.rawValue,
            ActivityEvent.Kind.brainRouteTargetSkipped.rawValue,
        ])
    }

    /// Failure notices keep their fixed frames, which row styling and the legacy human-facing filter
    /// key on, and quote the provider's identity and redacted message after the frame, so a
    /// screenshot of Activity is enough to diagnose a failure nobody has classified yet.
    @Test func runtimeFailureNoticesKeepTheirFramesAndQuoteTheProvider() {
        let leaky = ProviderFailure(
            source: .brain(.codexCLI), stage: .process, category: .unknown,
            disposition: .temporary, identity: .init(exitStatus: 1),
            message: "OAuth token expired; Authorization: Bearer abc123token")
        let capture = ProviderFailure(
            source: .capture, stage: .local, category: .unavailable, disposition: .permanent,
            identity: .init(), message: "no input device")
        let region = ProviderFailure(
            source: .transcription(.openAI), stage: .handshake, category: .access,
            disposition: .permanent,
            identity: .init(httpStatus: 403, errorCode: "unsupported_country_region_territory"),
            message: "Country, region, or territory not supported")
        let lost = ProviderFailure(
            source: .transcription(.openAI), stage: .close, category: .disconnected,
            disposition: .temporary, identity: .init(closeCode: 1006), message: "")
        let events: [ActivityEvent] = [
            .sessionEnded(reason: .transcriptionStopped(failure: region)),
            .sessionEnded(reason: .brainRouteExhausted(last: leaky)),
            .sessionEnded(reason: .audioCaptureUnavailable(failure: capture)),
            .coachingCycleFailed(failure: leaky),
            .systemAudioStopped(failure: lost),
            .settingsChangeNotApplied,
        ]
        let messages = events.map { $0.rendered.message }

        #expect(messages.count == 6)
        #expect(messages[0] == "⏹ session ended by error — OpenAI denied access (HTTP 403, unsupported_country_region_territory: Country, region, or territory not supported); check your region, VPN, or API project")
        #expect(ActivityLog.cssClass(for: messages[0]) == "err")
        #expect(messages[1] == "⏹ session ended by error — all configured provider targets were exhausted; last target: Codex CLI failed (exit 1: OAuth token expired; Authorization: Bearer …)")
        #expect(ActivityLog.cssClass(for: messages[1]) == "err")
        #expect(messages[2] == "⏹ session ended by error — audio capture became unavailable (no input device)")
        #expect(messages[3] == "⚠️ Codex CLI failed (exit 1: OAuth token expired; Authorization: Bearer …) — coaching failed; listening continues")
        #expect(messages[4] == "⚠️ system audio stopped — the transcription connection to OpenAI was lost (close 1006); microphone coaching continues")
        #expect(messages[5].contains("current coaching session continues"))
        // Provider text reaches a row only after redaction, so a quoted message can never carry a
        // credential.
        #expect(messages.allSatisfy { !$0.contains("abc123token") })
        for message in messages {
            #expect(ActivityLog.isHumanFacing(message: message, imageFile: nil))
        }
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ system audio stopped — microphone coaching continues; check jarvis-debug.log",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⏹ session ended by error — the transcription API quota is exhausted; check billing",
            imageFile: nil
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⚠️ settings change wasn't applied — current coaching session continues; check Settings → Brain",
            imageFile: nil
        ))
    }

    @Test func sessionEndReasonsAreExplicitSanitizedAndStable() {
        let leaky = ProviderFailure(
            source: .brain(.codexCLI), stage: .process, category: .unknown,
            disposition: .temporary, identity: .init(exitStatus: 1),
            message: "OAuth token expired; Authorization: Bearer abc123token")
        let capture = ProviderFailure(
            source: .capture, stage: .local, category: .unavailable, disposition: .permanent,
            identity: .init(), message: "no input device")
        let region = ProviderFailure(
            source: .transcription(.openAI), stage: .handshake, category: .access,
            disposition: .permanent,
            identity: .init(httpStatus: 403, errorCode: "unsupported_country_region_territory"),
            message: "Country, region, or territory not supported")
        let reasons: [SessionEndReason] = [
            .stoppedByUser,
            .applicationQuit,
            .replacedByNewSession,
            .openAIAPIKeyMissing,
            .permissionsMissing,
            .brainRouteExhausted(last: leaky),
            .transcriptionStopped(failure: region),
            .audioCaptureUnavailable(failure: capture),
            .unexpectedError(detail: "Couldn't prepare Apple Speech"),
            .brainRecoveryExpired(last: leaky),
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
        #expect(messages[5] == "⏹ session ended by error — all configured provider targets were exhausted; last target: Codex CLI failed (exit 1: OAuth token expired; Authorization: Bearer …)")
        #expect(messages[6] == "⏹ session ended by error — OpenAI denied access (HTTP 403, unsupported_country_region_territory: Country, region, or territory not supported); check your region, VPN, or API project")
        #expect(ActivityLog.cssClass(for: messages[6]) == "err")
        #expect(messages[7] == "⏹ session ended by error — audio capture became unavailable (no input device)")
        #expect(messages[8] == "⏹ session ended by error — Couldn't prepare Apple Speech")
        #expect(messages[9] == "⏹ session ended by error — coaching kept failing for 10 minutes; last error: Codex CLI failed (exit 1: OAuth token expired; Authorization: Bearer …)")
        #expect(ActivityLog.cssClass(for: messages[9]) == "err")
        #expect(messages.allSatisfy { !$0.contains("abc123token") })
        #expect(rendered.map { $0.kind } == Array(
            repeating: ActivityEvent.Kind.sessionEnded,
            count: reasons.count
        ))
        #expect(ActivityLog.isHumanFacing(
            message: "⏹ session ended by user",
            imageFile: nil
        ))
    }

    /// The message and event kind of each persisted `jarvis-activity.jsonl` row, in file order.
    /// Reading the file is how a row's exact copy is asserted: `Snapshot.rows` are `appendRow(...)`
    /// scripts, not messages. Malformed lines are dropped, so tests assert the count they expect.
    static func persistedRows(in directory: URL) throws -> [(message: String, kind: String?)] {
        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(ActivityLog.filename), encoding: .utf8)
        return jsonl.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let value = object as? [String: Any],
                  let message = value["m"] as? String
            else { return nil }
            return (message, value["k"] as? String)
        }
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
