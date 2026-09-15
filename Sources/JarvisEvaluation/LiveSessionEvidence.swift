import Foundation
import JarvisCore

/// A read-only view of one live session folder, for assertions. The live e2e tests and the app's
/// e2e runner ask it which Activity rows, coaching attempts, and brain requests a scripted session
/// produced.
///
/// It joins what the writers keep apart: brain traffic names its attempt, but Activity rows do not,
/// so rows are attributed to attempts by time (`attributeRows`). It reports what was written and
/// never decides whether that was correct; the caller asserts.
public struct LiveSessionEvidence: Sendable {
    public enum ReadError: Error, Equatable {
        /// The folder name carries no `yyyy-MM-dd_HH-mm-ss` stamp, so attempt clock times have no date.
        case undatedSessionDirectory(name: String)
    }

    public struct LoadedCapability: Sendable, Equatable {
        public let name: String
        /// `tool` or `skill`.
        public let kind: String

        public init(name: String, kind: String) {
            self.name = name
            self.kind = kind
        }
    }

    /// One `jarvis-activity.jsonl` row.
    public struct ActivityRow: Sendable, Equatable {
        /// Zero-based position among the file's parseable rows, in file order.
        public let index: Int
        /// The persisted `ActivityEvent.Kind` raw value; nil for rows written before kinds existed.
        public let kind: String?
        public let message: String
        /// Fractional Unix seconds when the occurrence happened. A `heard` row carries speech time,
        /// which can be earlier than when the row was written.
        public let occurredAt: TimeInterval?
        /// Parsed from a `capabilityLoaded` row's message, the only place the row names what it loaded.
        public let loadedCapability: LoadedCapability?
    }

    public struct TranscriptEntry: Sendable, Equatable {
        public let speaker: String
        public let text: String
        /// Session-relative speech time. The record keeps lines in insertion order; this is the time
        /// `ConversationChronology` orders them by for the model.
        public let at: TimeInterval?

        public init(speaker: String, text: String, at: TimeInterval? = nil) {
            self.speaker = speaker
            self.text = text
            self.at = at
        }
    }

    /// One coaching attempt: its `started` record and, once it ended, its `finished` record.
    public struct Attempt: Sendable, Equatable {
        public let id: Int
        /// Zero-based position of the `started` record among the parseable records of
        /// `coaching-attempts.jsonl`.
        public let startedRecordIndex: Int
        public let finishedRecordIndex: Int?
        /// Whole-second Unix time: the record's local `HH:mm:ss` stamp, dated from the session.
        public let startedAt: TimeInterval?
        /// Nil while the attempt has no finished record.
        public let finishedAt: TimeInterval?
        public let trigger: String
        public let sourceTrigger: String
        public let wake: String
        public let provider: String
        public let model: String
        public let terminal: String?
        public let outcome: String?
        public let transcript: [TranscriptEntry]

        /// Whether the attempt's turn was committed to session history. Only a spoken or deliberately
        /// silent turn commits, so a capability loaded inside a failed attempt was never kept.
        public var isCommitted: Bool {
            outcome == "spoke" || outcome == "silent_by_model"
        }
    }

    /// The `mermaid` argument of the speak call in a brain response.
    public enum SpeakDiagram: Sendable, Equatable {
        /// The response holds no speak call.
        case noSpeakCall
        /// The speak call's `mermaid` is null or absent.
        case none
        case present(String)
    }

    public struct FunctionCall: Sendable, Equatable {
        public let callID: String
        public let name: String
        /// The call's raw JSON arguments string.
        public let arguments: String

        public init(callID: String, name: String, arguments: String) {
            self.callID = callID
            self.name = name
            self.arguments = arguments
        }
    }

    /// One `brain-traffic.jsonl` record.
    public struct TrafficRecord: Sendable, Equatable {
        /// Zero-based position among the file's parseable records, in file order.
        public let index: Int
        /// `coach` or `summarizer`.
        public let tag: String
        /// `coach_attempt.id`; nil for a request made outside a coaching attempt.
        public let attemptID: Int?
        public let sourceTrigger: String?
        public let status: Int?
        public let error: String?
        /// The `BrainProvider` raw value that served the request; nil when the record names none.
        public let provider: String?
        public let instructions: String?
        /// `request.tools[].name`, in order.
        public let declaredToolNames: [String]
        /// A string `tool_choice` itself (`auto`, `required`), or an object choice's `type`
        /// (`allowed_tools`, `function`).
        public let toolChoiceType: String?
        /// OpenAI `request.input` items of type `function_call`, in order: the replayed tool loop.
        public let replayedFunctionCalls: [FunctionCall]
        /// OpenAI `request.input` items of type `function_call_output`, by `call_id`, in order.
        public let replayedFunctionOutputCallIDs: [String]
        public let speakDiagram: SpeakDiagram
    }

    public let activity: [ActivityRow]
    /// Ordered by started record.
    public let attempts: [Attempt]
    public let traffic: [TrafficRecord]
    public let debugLines: [String]
    public let healthState: String?
    /// Unparseable non-blank lines across `jarvis-activity.jsonl`, `coaching-attempts.jsonl`, and
    /// `brain-traffic.jsonl`.
    public let malformedRecordCount: Int
    /// For each Activity row, by position, the index into `attempts` it was attributed to.
    private let rowAttempts: [Int?]

    /// Reads the five session files; a missing file reads as empty (health as nil). Throws only when
    /// the directory name carries no parseable date.
    public init(sessionDirectory: URL) throws {
        let name = sessionDirectory.lastPathComponent
        guard let sessionDate = Self.parseSessionDate(fromDirectoryName: name) else {
            throw ReadError.undatedSessionDirectory(name: name)
        }
        self.init(
            activityJSONL: Self.read(ActivityLog.filename, in: sessionDirectory) ?? "",
            attemptsJSONL: Self.read(FileSessionAudit.coachingAttemptsFilename, in: sessionDirectory) ?? "",
            trafficJSONL: Self.read(FileSessionAudit.brainTrafficFilename, in: sessionDirectory) ?? "",
            debugLog: Self.read(FileSessionAudit.diagnosticFilename, in: sessionDirectory) ?? "",
            healthJSON: Self.read(FileSessionAudit.healthFilename, in: sessionDirectory),
            sessionDate: sessionDate)
    }

    /// For tests and callers that already hold the contents. `sessionDate` is the session's start:
    /// its local calendar day dates the attempt stamps and its local clock time seeds midnight
    /// detection.
    public init(
        activityJSONL: String,
        attemptsJSONL: String,
        trafficJSONL: String,
        debugLog: String,
        healthJSON: String?,
        sessionDate: Date
    ) {
        let activityRecords = JSONLRecords.parse(activityJSONL)
        let attemptRecords = JSONLRecords.parse(attemptsJSONL)
        let trafficRecords = JSONLRecords.parse(trafficJSONL)
        let activity = Self.parseActivity(activityRecords.objects)
        let attempts = Self.parseAttempts(attemptRecords.objects, sessionDate: sessionDate)
        self.activity = activity
        self.attempts = attempts
        self.traffic = trafficRecords.objects.enumerated().map { index, object in
            Self.parseTraffic(object, index: index)
        }
        self.debugLines = debugLog.split(whereSeparator: \.isNewline).map(String.init)
        self.healthState = Self.parseHealthState(healthJSON)
        self.malformedRecordCount = activityRecords.malformedCount
            + attemptRecords.malformedCount
            + trafficRecords.malformedCount
        self.rowAttempts = Self.attributeRows(activity, to: attempts)
    }

    public func attempt(id: Int) -> Attempt? {
        attempts.first { $0.id == id }
    }

    /// Activity rows attributed to an attempt (see `attributeRows`), in file order.
    public func rows(in attempt: Attempt) -> [ActivityRow] {
        guard let target = attempts.firstIndex(where: {
            $0.startedRecordIndex == attempt.startedRecordIndex
        }) else { return [] }
        return activity.filter { rowAttempts[$0.index] == target }
    }

    /// Coach-tagged traffic records whose `coach_attempt.id` equals the attempt id, in file order.
    public func traffic(for attempt: Attempt) -> [TrafficRecord] {
        traffic.filter { $0.tag == "coach" && $0.attemptID == attempt.id }
    }

    /// Whether a provider request timed out and failed the attempt. The CLI runtimes report a
    /// timeout in words; the OpenAI client records only error codes, and a URL timeout is -1001.
    public func failedOnProviderStall(_ attempt: Attempt) -> Bool {
        guard attempt.outcome == "brain_error",
              let error = traffic(for: attempt).last(where: { $0.error != nil })?.error else {
            return false
        }
        return error.localizedCaseInsensitiveContains("timed out")
            || error.contains("error_code=\(NSURLErrorTimedOut)")
    }

    /// The attempt, followed by the retries its provider stalls caused.
    ///
    /// The app retries failed work on the same target as a `pending_work` attempt. While the chain's
    /// last attempt failed on a provider stall, the attempt right after it joins when it is that
    /// retry. Any other failure ends the chain, so only a stall is judged through its retry, and so
    /// does a committed attempt, so `pending_work` that batches later speech is never absorbed.
    public func retryChain(from attempt: Attempt) -> [Attempt] {
        guard var position = attempts.firstIndex(where: {
            $0.startedRecordIndex == attempt.startedRecordIndex
        }) else { return [attempt] }
        var chain = [attempts[position]]
        while let last = chain.last, failedOnProviderStall(last), position + 1 < attempts.count {
            let next = attempts[position + 1]
            guard next.trigger == "pending_work", next.sourceTrigger == last.sourceTrigger,
                  next.provider == last.provider else { break }
            chain.append(next)
            position += 1
        }
        return chain
    }

    /// Activity rows of a retry chain, in file order. A failed attempt's screen and prep-notes
    /// observations carry into its retry, so their rows belong to the chain; its capability loads
    /// are discarded with it (see `committedLoads`), so those rows do not.
    public func rows(inChain chain: [Attempt]) -> [ActivityRow] {
        chain.flatMap { attempt in
            rows(in: attempt).filter { attempt.isCommitted || $0.loadedCapability == nil }
        }
    }

    public func debugLines(containing needle: String) -> [String] {
        debugLines.filter { $0.contains(needle) }
    }

    /// `capabilityLoaded` rows attributed to committed attempts, in row order. A load row is written
    /// when the load happens, but the loaded set is kept only if its attempt commits, so uniqueness
    /// and order checks belong over this list rather than over every load row.
    public var committedLoads: [LoadedCapability] {
        activity.compactMap { row in
            guard let capability = row.loadedCapability,
                  let attemptIndex = rowAttempts[row.index],
                  attempts[attemptIndex].isCommitted
            else { return nil }
            return capability
        }
    }

    /// Assigns each Activity row to the coaching attempt it happened in, or to none.
    ///
    /// Rows carry no attempt id, so the join is by time. A row is a candidate for an attempt when
    /// `startedAt <= floor(occurredAt) <= finishedAt`, and an attempt with no finished record stays
    /// open to the end of the session. Attempts are strictly serialized, but their stamps are whole
    /// seconds: when work is pending, attempt n's finished record and attempt n+1's started record
    /// are written within the same second, so a row in that second is a candidate for both, and time
    /// alone cannot split it.
    ///
    /// File order splits it. The one evidence worker appends rows in the order they were recorded,
    /// so rows are walked in file order behind a cursor at the earliest attempt still open. A row
    /// goes to the first candidate at or after the cursor. A terminal row (a tip, a deliberate
    /// silence, or a failed coaching cycle, which is written before its attempt's finished record)
    /// closes its attempt by moving the cursor past it, so the rows after it in a shared second go to
    /// the next attempt.
    ///
    /// What follows from the rule: rows between attempts and rows without an occurrence time stay
    /// unattributed. The cursor never moves backward, so a late row whose time falls inside an
    /// already closed attempt stays unattributed too. A failed attempt that did not end its cycle
    /// writes no terminal row, so rows in the second its retry starts go to the failed attempt.
    private static func attributeRows(_ rows: [ActivityRow], to attempts: [Attempt]) -> [Int?] {
        let terminalKinds: Set<String> = [
            ActivityEvent.Kind.tip.rawValue,
            ActivityEvent.Kind.stayedSilent.rawValue,
            ActivityEvent.Kind.coachingCycleFailed.rawValue,
        ]
        var cursor = 0
        return rows.map { row in
            guard let occurredAt = row.occurredAt else { return nil }
            let second = occurredAt.rounded(.down)
            guard let match = attempts.indices.dropFirst(cursor).first(where: { index in
                guard let startedAt = attempts[index].startedAt else { return false }
                return startedAt <= second && second <= (attempts[index].finishedAt ?? .infinity)
            }) else { return nil }
            if let kind = row.kind, terminalKinds.contains(kind) {
                cursor = match + 1
            }
            return match
        }
    }

    private static func read(_ filename: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(filename), encoding: .utf8)
    }
}
