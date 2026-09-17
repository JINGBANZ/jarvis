import Foundation
import JarvisCore
import JarvisEvaluation
import Testing

/// No `@testable`: the live test target reads sessions through the public API alone.
@Suite struct LiveSessionEvidenceTests {
    typealias Evidence = LiveSessionEvidence

    // MARK: - Fixtures

    /// Attempt stamps are local clock times, so a hard-coded epoch would hold in one time zone
    /// only.
    static func local(day: Int = 14, _ hour: Int, _ minute: Int, _ second: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second)))
    }

    static func unix(day: Int = 14, _ hour: Int, _ minute: Int, _ second: Int) throws -> TimeInterval {
        try local(day: day, hour, minute, second).timeIntervalSince1970
    }

    static func line(_ object: [String: Any]) throws -> String {
        try #require(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8))
    }

    static func row(_ kind: String, _ message: String, at occurredAt: TimeInterval?) throws -> String {
        var object: [String: Any] = ["k": kind, "m": message, "q": 0]
        if let occurredAt { object["o"] = occurredAt }
        return try line(object)
    }

    static func started(
        _ id: Int,
        at t: String,
        sourceTrigger: String = "turn_end",
        trigger: String? = nil,
        provider: String = "openai",
        transcript: [[String: Any]] = []
    ) throws -> String {
        let trigger = trigger ?? sourceTrigger
        return try line([
            "audit_version": 1, "event": "started", "attempt": id, "t": t,
            "wake": trigger == "pending_work" ? "pending_work" : "trigger",
            "trigger": trigger, "source_trigger": sourceTrigger,
            "provider": provider, "model": "gpt-5.5", "transcript": transcript,
        ])
    }

    static func finished(
        _ id: Int,
        at t: String,
        terminal: String = "speak",
        outcome: String = "spoke"
    ) throws -> String {
        try line([
            "audit_version": 1, "event": "finished", "attempt": id, "t": t,
            "terminal": terminal, "outcome": outcome,
        ])
    }

    static func evidence(
        activity: [String] = [],
        attempts: [String] = [],
        traffic: [String] = [],
        debugLog: String = "",
        healthJSON: String? = nil,
        sessionDate: Date? = nil
    ) throws -> Evidence {
        Evidence(
            activityJSONL: activity.joined(separator: "\n"),
            attemptsJSONL: attempts.joined(separator: "\n"),
            trafficJSONL: traffic.joined(separator: "\n"),
            debugLog: debugLog,
            healthJSON: healthJSON,
            sessionDate: try sessionDate ?? local(9, 0, 0))
    }

    static func coachRecord(
        attempt id: Int?,
        request: [String: Any] = [:],
        response: [String: Any]? = nil,
        error: String? = nil,
        tag: String = "coach"
    ) throws -> String {
        var object: [String: Any] = ["tag": tag, "t": "10:00:00", "ms": 800, "request": request]
        if let error { object["error"] = error }
        if let id {
            object["coach_attempt"] = [
                "id": id, "trigger": "turn_end", "source_trigger": "turn_end",
                "phase": "initial", "sequence": 1,
            ] as [String: Any]
        }
        if let response {
            object["status"] = 200
            object["response"] = response
        }
        return try line(object)
    }

    // MARK: - Activity rows

    @Test func loadRowsNameTheirCapabilityAndOtherRowsDoNot() throws {
        let evidence = try Self.evidence(activity: [
            Self.row("capabilityLoaded", "📎 loaded the search_prep_notes tool", at: 10.5),
            Self.row("capabilityLoaded", "📎 loaded the system-design skill", at: 11),
            Self.row("tip", "📎 loaded the coding skill", at: 12),
            Self.row("capabilityLoaded", "📎 loaded the coding widget", at: 13),
            #"{"m":"🗣 heard (them): \"hello\"","t":"10:00:00"}"#,
        ])

        #expect(evidence.activity.map(\.loadedCapability) == [
            Evidence.LoadedCapability(name: "search_prep_notes", kind: "tool"),
            Evidence.LoadedCapability(name: "system-design", kind: "skill"),
            nil,
            nil,
            nil,
        ])
        #expect(evidence.activity.map(\.index) == [0, 1, 2, 3, 4])
        #expect(evidence.activity[0].kind == "capabilityLoaded")
        #expect(evidence.activity[0].occurredAt == 10.5)
        let legacy = try #require(evidence.activity.last)
        #expect(legacy.kind == nil)
        #expect(legacy.occurredAt == nil)
        #expect(legacy.message == #"🗣 heard (them): "hello""#)
    }

    // MARK: - Attempts

    @Test func attemptsPairTheirRecordsAndAnUnfinishedAttemptStaysOpen() throws {
        let evidence = try Self.evidence(attempts: [
            Self.started(1, at: "10:00:00", transcript: [
                [
                    "index": 0, "speaker": "them", "text": "Design a rate limiter.", "at": 1.5,
                    "classification": "substantive", "brain_facing": true,
                ],
                [
                    "index": 1, "speaker": "me", "text": "Sure.", "at": 3.0,
                    "classification": "known_filler", "brain_facing": false,
                ],
            ]),
            Self.finished(9, at: "10:00:01"),
            Self.finished(1, at: "10:00:04"),
            Self.started(2, at: "10:00:06", sourceTrigger: "manual_hint"),
        ])
        let firstStart = try Self.unix(10, 0, 0)
        let firstFinish = try Self.unix(10, 0, 4)
        let secondStart = try Self.unix(10, 0, 6)

        #expect(evidence.attempts.map(\.id) == [1, 2])
        #expect(evidence.attempt(id: 9) == nil)

        let first = try #require(evidence.attempt(id: 1))
        #expect(first.startedRecordIndex == 0)
        #expect(first.finishedRecordIndex == 2)
        #expect(first.startedAt == firstStart)
        #expect(first.finishedAt == firstFinish)
        #expect(first.trigger == "turn_end")
        #expect(first.sourceTrigger == "turn_end")
        #expect(first.wake == "trigger")
        #expect(first.provider == "openai")
        #expect(first.model == "gpt-5.5")
        #expect(first.terminal == "speak")
        #expect(first.outcome == "spoke")
        #expect(first.isCommitted)
        #expect(first.transcript == [
            Evidence.TranscriptEntry(speaker: "them", text: "Design a rate limiter.", at: 1.5),
            Evidence.TranscriptEntry(speaker: "me", text: "Sure.", at: 3.0),
        ])

        let second = try #require(evidence.attempt(id: 2))
        #expect(second.startedRecordIndex == 3)
        #expect(second.finishedRecordIndex == nil)
        #expect(second.startedAt == secondStart)
        #expect(second.finishedAt == nil)
        #expect(second.sourceTrigger == "manual_hint")
        #expect(second.terminal == nil)
        #expect(second.outcome == nil)
        #expect(!second.isCommitted)
    }

    @Test func clockStampsAreDatedFromTheSessionAndRollOverAtMidnight() throws {
        let crossing = try Self.evidence(
            attempts: [
                Self.started(1, at: "23:59:55"),
                Self.finished(1, at: "23:59:59"),
                Self.started(2, at: "00:00:01"),
                Self.finished(2, at: "00:00:04"),
            ],
            sessionDate: Self.local(23, 59, 50))
        let starts: [TimeInterval?] = try [Self.unix(23, 59, 55), Self.unix(day: 15, 0, 0, 1)]
        let finishes: [TimeInterval?] = try [Self.unix(23, 59, 59), Self.unix(day: 15, 0, 0, 4)]
        #expect(crossing.attempts.map(\.startedAt) == starts)
        #expect(crossing.attempts.map(\.finishedAt) == finishes)

        let lateFirst = try Self.evidence(
            attempts: [Self.started(1, at: "00:00:02"), Self.finished(1, at: "00:00:02")],
            sessionDate: Self.local(23, 59, 50))
        let afterMidnight = try Self.unix(day: 15, 0, 0, 2)
        #expect(lateFirst.attempts.first?.startedAt == afterMidnight)
        #expect(lateFirst.attempts.first?.finishedAt == afterMidnight)

        let sameSecond = try Self.evidence(
            attempts: [Self.started(1, at: "09:00:00")],
            sessionDate: Self.local(9, 0, 0))
        let sessionStart = try Self.unix(9, 0, 0)
        #expect(sameSecond.attempts.first?.startedAt == sessionStart)
    }

    // MARK: - Attribution

    @Test func rowsJoinTheirAttemptByTimeAndBreakEqualSecondTiesByFileOrder() throws {
        let base = try Self.unix(10, 0, 0)
        let evidence = try Self.evidence(
            activity: [
                Self.row("heard", "🗣 heard (them): \"Design a feed.\"", at: base - 1.5),
                // 1, 2, 3: attempt 1; its tip lands in the second attempt 2 starts in.
                Self.row("manualHint", "⌨️ hint shortcut — help", at: base + 0.1),
                Self.row("screenViewed", "👁 looking at your screen", at: base + 2),
                Self.row("tip", "💬 Start with the write path.", at: base + 5.2),
                // 4: speech time inside attempt 1, written after that attempt closed.
                Self.row("heard", "🗣 heard (me): \"Okay.\"", at: base + 4),
                // 5: the shared second; time alone makes it a candidate for both attempts.
                Self.row("screenViewed", "👁 looking at your screen", at: base + 5.7),
                Self.row("heard", "🗣 heard (them): \"Go on.\"", at: nil),
                Self.row("tip", "💬 Add a fan-out cache.", at: base + 8.9),
                Self.row("heard", "🗣 heard (them): \"Thanks.\"", at: base + 12),
                Self.row("sessionEnded", "⏹ session ended by user", at: base + 15),
            ],
            attempts: [
                Self.started(1, at: "10:00:00"),
                Self.finished(1, at: "10:00:05"),
                Self.started(2, at: "10:00:05"),
                Self.finished(2, at: "10:00:09"),
            ])

        let first = try #require(evidence.attempt(id: 1))
        let second = try #require(evidence.attempt(id: 2))
        #expect(evidence.rows(in: first).map(\.index) == [1, 2, 3])
        #expect(evidence.rows(in: second).map(\.index) == [5, 7])
        #expect(evidence.rows(in: second).map(\.kind) == ["screenViewed", "tip"])
        let attributed = Set((evidence.rows(in: first) + evidence.rows(in: second)).map(\.index))
        #expect(evidence.activity.map(\.index).filter { !attributed.contains($0) } == [0, 4, 6, 8, 9])
    }

    @Test func aFailedCycleRowClosesItsAttemptAndAnUnfinishedAttemptStaysOpen() throws {
        let base = try Self.unix(11, 0, 0)
        let evidence = try Self.evidence(
            activity: [
                Self.row(
                    "coachingTurnFailed",
                    "⚠️ OpenAI couldn't respond — coaching failed; listening continues",
                    at: base + 3.1),
                Self.row("screenViewed", "👁 looking at your screen", at: base + 3.5),
                Self.row("tip", "💬 Much later.", at: base + 20 * 60),
            ],
            attempts: [
                Self.started(1, at: "11:00:00"),
                Self.finished(1, at: "11:00:03", terminal: "exhaustion", outcome: "brain_error"),
                Self.started(2, at: "11:00:03"),
            ])

        let failed = try #require(evidence.attempt(id: 1))
        let open = try #require(evidence.attempt(id: 2))
        #expect(evidence.rows(in: failed).map(\.index) == [0])
        #expect(evidence.rows(in: open).map(\.index) == [1, 2])
    }

    @Test func committedLoadsSkipALoadInsideAFailedAttempt() throws {
        let base = try Self.unix(10, 0, 0)
        let evidence = try Self.evidence(
            activity: [
                Self.row("capabilityLoaded", "📎 loaded the coding skill", at: base + 2),
                Self.row("capabilityLoaded", "📎 loaded the coding skill", at: base + 7),
                Self.row("stayedSilent", "🤫 stayed silent — nothing useful to add", at: base + 8),
                Self.row("capabilityLoaded", "📎 loaded the search_prep_notes tool", at: base + 11),
                Self.row("prepNotesSearched", "📎 checked prep notes for \"caching\" — found 2 matches", at: base + 12),
                Self.row("tip", "💬 Mention the cache.", at: base + 13),
                Self.row("capabilityLoaded", "📎 loaded the behavioral skill", at: base + 20),
            ],
            attempts: [
                Self.started(1, at: "10:00:00"),
                Self.finished(1, at: "10:00:04", terminal: "failure", outcome: "brain_error"),
                Self.started(2, at: "10:00:06"),
                Self.finished(2, at: "10:00:09", terminal: "stay_silent", outcome: "silent_by_model"),
                Self.started(3, at: "10:00:10"),
                Self.finished(3, at: "10:00:14"),
            ])

        let failed = try #require(evidence.attempt(id: 1))
        #expect(evidence.rows(in: failed).map(\.loadedCapability) == [
            Evidence.LoadedCapability(name: "coding", kind: "skill"),
        ])
        #expect(evidence.committedLoads == [
            Evidence.LoadedCapability(name: "coding", kind: "skill"),
            Evidence.LoadedCapability(name: "search_prep_notes", kind: "tool"),
        ])
    }

    // MARK: - Retry chains

    @Test func aStalledAttemptIsJudgedThroughTheRetryThatAnswered() throws {
        let base = try Self.unix(11, 50, 0)
        let evidence = try Self.evidence(
            activity: [
                Self.row("manualHint", "⌨️ hint shortcut — help", at: base + 0.9),
                Self.row("screenViewed", "👁 looking at your screen", at: base + 1.4),
                Self.row("capabilityLoaded", "📎 loaded the coding skill", at: base + 4.1),
                Self.row("capabilityLoaded", "📎 loaded the coding skill", at: base + 22.6),
                Self.row("tip", "💬 Sort intervals by start first.", at: base + 25.6),
                Self.row("heard", "🗣 heard (them): \"Great, thanks for joining.\"", at: base + 26),
                Self.row("stayedSilent", "🤫 stayed silent — nothing useful to add", at: base + 33),
            ],
            attempts: [
                Self.started(1, at: "11:50:00", sourceTrigger: "manual_hint", provider: "claude-code"),
                Self.finished(1, at: "11:50:19", terminal: "failure", outcome: "brain_error"),
                Self.started(
                    2, at: "11:50:19", sourceTrigger: "manual_hint", trigger: "pending_work",
                    provider: "claude-code"),
                Self.finished(2, at: "11:50:25"),
                Self.started(3, at: "11:50:31", provider: "claude-code"),
                Self.finished(3, at: "11:50:33", terminal: "stay_silent", outcome: "silent_by_model"),
            ],
            traffic: [
                Self.coachRecord(attempt: 1, response: ["reply": "{}"]),
                Self.coachRecord(
                    attempt: 1,
                    error: "Claude did not finish the turn within 15s (elapsed 15004ms; system/init×1) "
                        + "— local agent runtime timed out after 14s"),
                Self.coachRecord(attempt: 2, response: ["reply": "{}"]),
            ])
        let pressed = try #require(evidence.attempt(id: 1))
        let next = try #require(evidence.attempt(id: 3))
        let chain = evidence.retryChain(from: pressed)

        #expect(evidence.failedOnProviderStall(pressed))
        #expect(chain.map(\.id) == [1, 2])
        // The screen view carries into the retry; the failed attempt's load does not.
        #expect(evidence.rows(inChain: chain).map(\.index) == [0, 1, 3, 4])
        #expect(evidence.retryChain(from: next).map(\.id) == [3])
    }

    @Test func aChainFollowsOnlyStallsAndStopsAtTheTurnThatCommits() throws {
        let evidence = try Self.evidence(
            attempts: [
                // 1, 2: a CLI that exits at once is not a stall, so no retry joins.
                Self.started(1, at: "11:32:32", provider: "claude-code"),
                Self.finished(1, at: "11:32:32", terminal: "failure", outcome: "brain_error"),
                Self.started(2, at: "11:32:32", trigger: "pending_work", provider: "claude-code"),
                Self.finished(2, at: "11:32:32", terminal: "failure", outcome: "brain_error"),
                // 3, 4, 5: three timeouts exhaust the target.
                Self.started(3, at: "11:40:00"),
                Self.finished(3, at: "11:40:15", terminal: "failure", outcome: "brain_error"),
                Self.started(4, at: "11:40:15", trigger: "pending_work"),
                Self.finished(4, at: "11:40:30", terminal: "failure", outcome: "brain_error"),
                Self.started(5, at: "11:40:30", trigger: "pending_work"),
                Self.finished(5, at: "11:40:45", terminal: "exhaustion", outcome: "brain_error"),
                // 6, 7: a committed turn, then pending work batched from later speech.
                Self.started(6, at: "11:50:00"),
                Self.finished(6, at: "11:50:05"),
                Self.started(7, at: "11:50:05", trigger: "pending_work"),
                Self.finished(7, at: "11:50:09"),
            ],
            traffic: [
                Self.coachRecord(attempt: 1, error: "local agent runtime stopped (exit 1)"),
                Self.coachRecord(attempt: 2, error: "local agent runtime stopped (exit 1)"),
                Self.coachRecord(attempt: 3, error: "error_domain=NSURLErrorDomain error_code=-1001"),
                Self.coachRecord(attempt: 4, error: "error_domain=NSURLErrorDomain error_code=-1001"),
                Self.coachRecord(attempt: 5, error: "error_domain=NSURLErrorDomain error_code=-1001"),
                Self.coachRecord(attempt: 6, response: ["reply": "{}"]),
                Self.coachRecord(attempt: 7, response: ["reply": "{}"]),
            ])
        let exited = try #require(evidence.attempt(id: 1))
        let timedOut = try #require(evidence.attempt(id: 3))
        let committed = try #require(evidence.attempt(id: 6))

        #expect(!evidence.failedOnProviderStall(exited))
        #expect(evidence.retryChain(from: exited).map(\.id) == [1])
        #expect(evidence.failedOnProviderStall(timedOut))
        #expect(evidence.retryChain(from: timedOut).map(\.id) == [3, 4, 5])
        #expect(!evidence.failedOnProviderStall(committed))
        #expect(evidence.retryChain(from: committed).map(\.id) == [6])
    }

    // MARK: - Traffic

    @Test func trafficJoinsItsAttemptByCoachAttemptID() throws {
        let evidence = try Self.evidence(
            attempts: [
                Self.started(7, at: "10:00:00"),
                Self.finished(7, at: "10:00:04"),
                Self.started(8, at: "10:00:05"),
            ],
            traffic: [
                Self.coachRecord(attempt: 7),
                Self.coachRecord(attempt: 8),
                Self.coachRecord(attempt: nil, tag: "summarizer"),
                Self.coachRecord(attempt: 7),
                Self.coachRecord(attempt: 7, tag: "summarizer"),
            ])

        let seven = try #require(evidence.attempt(id: 7))
        let eight = try #require(evidence.attempt(id: 8))
        #expect(evidence.traffic(for: seven).map(\.index) == [0, 3])
        #expect(evidence.traffic(for: eight).map(\.index) == [1])
        #expect(evidence.traffic.map(\.tag) == ["coach", "coach", "summarizer", "coach", "summarizer"])
        #expect(evidence.traffic[0].attemptID == 7)
        #expect(evidence.traffic[0].sourceTrigger == "turn_end")
        #expect(evidence.traffic[2].attemptID == nil)
    }

    @Test func openAIRequestsExposeDeclaredToolsToolChoiceAndReplayedCalls() throws {
        func tool(_ name: String) -> [String: Any] {
            ["type": "function", "name": name, "description": "", "strict": true,
             "parameters": ["type": "object"] as [String: Any]]
        }
        let allowedChoice: [String: Any] = [
            "type": "allowed_tools", "mode": "required",
            "tools": [["type": "function", "name": "speak"]],
        ]
        let input: [[String: Any]] = [
            ["role": "user", "content": [["type": "input_text", "text": "hello"]]],
            ["type": "function_call", "call_id": "cli_1a2b3c4d", "name": "load_skill",
             "arguments": #"{"name":"coding"}"#],
            ["type": "function_call_output", "call_id": "cli_1a2b3c4d", "output": "loaded"],
            ["type": "reasoning", "id": "rs_1", "summary": [String]()],
            ["type": "function_call", "call_id": "call_9", "name": "load_tool",
             "arguments": #"{"name":"search_prep_notes"}"#],
            ["type": "function_call_output", "call_id": "call_9", "output": "{}"],
        ]
        let allowed = try Self.coachRecord(
            attempt: 4,
            request: [
                "model": "gpt-5.5",
                "instructions": "You are Jarvis.",
                "tools": [tool("speak"), tool("stay_silent"), tool("load_skill"), tool("search_prep_notes")],
                "tool_choice": allowedChoice,
                "input": input,
            ],
            response: ["output": [[String: Any]]()])
        let required = try Self.line([
            "tag": "coach",
            "error": "The request timed out.",
            "request": [
                "model": "gpt-5.5", "tools": [tool("speak")], "tool_choice": "required",
                "input": [[String: Any]](),
            ] as [String: Any],
        ])

        let evidence = try Self.evidence(traffic: [allowed, required])
        let first = evidence.traffic[0]
        #expect(first.provider == nil)
        #expect(first.status == 200)
        #expect(first.error == nil)
        #expect(first.instructions == "You are Jarvis.")
        #expect(first.declaredToolNames == ["speak", "stay_silent", "load_skill", "search_prep_notes"])
        #expect(first.toolChoiceType == "allowed_tools")
        #expect(first.replayedFunctionCalls == [
            Evidence.FunctionCall(callID: "cli_1a2b3c4d", name: "load_skill", arguments: #"{"name":"coding"}"#),
            Evidence.FunctionCall(callID: "call_9", name: "load_tool", arguments: #"{"name":"search_prep_notes"}"#),
        ])
        #expect(first.replayedFunctionOutputCallIDs == ["cli_1a2b3c4d", "call_9"])

        let second = evidence.traffic[1]
        #expect(second.toolChoiceType == "required")
        #expect(second.status == nil)
        #expect(second.error == "The request timed out.")
        #expect(second.instructions == nil)
        #expect(second.replayedFunctionCalls.isEmpty)
        #expect(second.speakDetail == .noSpeakCall)
        #expect(second.speakParameters == nil)
    }

    @Test func archivedCLIRequestsExposeProviderAndInstructions() throws {
        let turn = try Self.coachRecord(
            attempt: 5,
            request: [
                "provider": "codex-cli",
                "model": "gpt-5.6-codex",
                "executable": "/opt/homebrew/bin/codex",
                "runtime": "app-server",
                "instructions": "## Tool protocol\nPick one tool.",
                "input": [["type": "text", "text": "## Conversation"]],
            ],
            response: ["reply": #"{"tool":"stay_silent","arguments":{}}"#])
        let failedOpen = try Self.line([
            "tag": "coach",
            "error": "local agent request timed out after 30.0s",
            "request": ["provider": "claude-code", "runtime": "query"],
        ])

        let evidence = try Self.evidence(traffic: [turn, failedOpen])
        let first = evidence.traffic[0]
        #expect(first.provider == "codex-cli")
        #expect(first.instructions == "## Tool protocol\nPick one tool.")
        #expect(first.declaredToolNames.isEmpty)
        #expect(first.toolChoiceType == nil)
        #expect(first.replayedFunctionCalls.isEmpty)
        #expect(first.replayedFunctionOutputCallIDs.isEmpty)
        #expect(first.speakDetail == .noSpeakCall)
        #expect(evidence.traffic[1].provider == "claude-code")
        #expect(evidence.traffic[1].instructions == nil)
    }

    @Test func speakDetailReadsTheResponsesOutput() throws {
        func detail(_ response: [String: Any]) throws -> Evidence.SpeakDetail {
            try Self.evidence(traffic: [Self.coachRecord(attempt: 1, response: response)])
                .traffic[0].speakDetail
        }
        func openAI(_ items: [[String: Any]]) -> [String: Any] {
            ["id": "resp_1", "status": "completed", "output": items]
        }
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "summary": [String]()]

        let graph = try detail(openAI([
            reasoning,
            ["type": "function_call", "call_id": "call_1", "name": "speak",
             "arguments": #"{"lines":["Sketch the write path."],"detail":"```mermaid\ngraph TD\nA-->B\n```"}"#],
        ]))
        #expect(graph == .present("```mermaid\ngraph TD\nA-->B\n```"))
        #expect(graph.fences.map(\.language) == ["mermaid"])
        #expect(graph.fences.first?.body == "graph TD\nA-->B")

        #expect(try detail(openAI([
            ["type": "function_call", "call_id": "call_2", "name": "speak",
             "arguments": #"{"lines":["Name the tradeoff."],"detail":null}"#],
        ])) == .none)
        #expect(try detail(openAI([
            ["type": "function_call", "call_id": "call_3", "name": "stay_silent", "arguments": "{}"],
        ])) == .noSpeakCall)
        #expect(try detail(["error": ["message": "Invalid request"] as [String: Any]]) == .noSpeakCall)
        #expect(Evidence.SpeakDetail.noSpeakCall.fences.isEmpty)
    }

    @Test func speakParametersReadTheDeclaredSchema() throws {
        let record = try Self.coachRecord(attempt: 1, request: [
            "model": "gpt-5.6-sol",
            "tools": [
                ["type": "function", "name": "speak",
                 "parameters": ["type": "object",
                                "properties": ["lines": ["type": "array"],
                                               "detail": ["type": ["string", "null"]]]]],
                ["type": "function", "name": "stay_silent", "parameters": ["type": "object"]],
            ],
        ], response: ["id": "resp_1", "status": "completed", "output": [[String: Any]]()])
        let evidence = try Self.evidence(traffic: [record])
        #expect(evidence.traffic[0].speakParameters == ["detail", "lines"])
    }

    // MARK: - Debug log, health, and malformed records

    @Test func debugLinesSplitTheLogAndFilterByNeedle() throws {
        let evidence = try Self.evidence(debugLog: """
            10:00:00.000 coaching ready (mic + system audio)
            10:00:01.250 🔤 read 12 lines of on-screen text

            10:00:02.500 Jarvis coach: tokens — input 900 (800 cached)

            """)

        #expect(evidence.debugLines.count == 3)
        #expect(evidence.debugLines(containing: "read 12 lines") == [
            "10:00:01.250 🔤 read 12 lines of on-screen text",
        ])
        #expect(evidence.debugLines(containing: "was already loaded").isEmpty)
    }

    @Test func malformedLinesAreCountedAcrossTheThreeJSONLFiles() throws {
        let evidence = try Self.evidence(
            activity: [
                Self.row("heard", "🗣 heard (them): \"one\"", at: 1),
                "{truncated",
                "",
                Self.row("tip", "💬 two", at: 2),
            ],
            attempts: ["[1]", Self.started(1, at: "10:00:00")],
            traffic: ["not json", Self.coachRecord(attempt: 1), "{\"tag\":"],
            healthJSON: #"{"state":"partial","version":1}"#)

        #expect(evidence.malformedRecordCount == 4)
        #expect(evidence.activity.map(\.index) == [0, 1])
        #expect(evidence.activity.map(\.kind) == ["heard", "tip"])
        #expect(evidence.attempts.first?.startedRecordIndex == 0)
        #expect(evidence.traffic.map(\.index) == [0])
        #expect(evidence.healthState == "partial")
        #expect(try Self.evidence(healthJSON: "{oops").healthState == nil)
        #expect(try Self.evidence().healthState == nil)
    }

    // MARK: - Session directory

    @Test func readsASessionDirectoryWithAMissingFile() throws {
        let root = tmp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("dev-2026-09-14_13-05-12_AB12", isDirectory: true)
        try FileManager.default.createDirectory(
            at: session, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let startedAt = try Self.unix(13, 5, 20)
        let activity = try Self.row("tip", "💬 Lead with the constraint.", at: startedAt + 2.5)
        let attempts = try [Self.started(1, at: "13:05:20"), Self.finished(1, at: "13:05:23")]
            .joined(separator: "\n") + "\n"
        let files = [
            ActivityLog.filename: activity + "\n",
            FileSessionAudit.coachingAttemptsFilename: attempts,
            FileSessionAudit.diagnosticFilename: "13:05:13.004 coaching ready (mic + system audio)\n",
            FileSessionAudit.healthFilename: #"{"state":"complete","version":1}"#,
        ]
        for (name, contents) in files {
            try Data(contents.utf8).write(to: session.appendingPathComponent(name))
        }

        let evidence = try Evidence(sessionDirectory: session)

        let attempt = try #require(evidence.attempt(id: 1))
        #expect(attempt.startedAt == startedAt)
        #expect(evidence.rows(in: attempt).map(\.kind) == ["tip"])
        #expect(evidence.traffic.isEmpty)
        #expect(evidence.debugLines == ["13:05:13.004 coaching ready (mic + system audio)"])
        #expect(evidence.healthState == "complete")
        #expect(evidence.malformedRecordCount == 0)

        #expect(throws: Evidence.ReadError.undatedSessionDirectory(name: "scratch")) {
            _ = try Evidence(sessionDirectory: root.appendingPathComponent("scratch"))
        }
    }
}
