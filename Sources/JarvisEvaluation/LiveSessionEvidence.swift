import Foundation
import JarvisBrainProviders
import JarvisCore

public struct LiveSessionEvidence: Sendable {
    public enum ReadError: Error, Equatable {
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

    public struct ActivityRow: Sendable, Equatable {
        /// Zero-based, counting parseable rows only.
        public let index: Int
        /// `ActivityEvent.Kind` raw value; nil on rows written before kinds existed.
        public let kind: String?
        public let message: String
        /// Fractional Unix seconds. A `heard` row carries speech time, which can precede the write.
        public let occurredAt: TimeInterval?
        /// Set only on `capabilityLoaded` rows, parsed from the message.
        public let loadedCapability: LoadedCapability?
        /// Set only on `tip` rows that persisted a structured response.
        public let response: ActivityResponse?
    }

    public struct TranscriptEntry: Sendable, Equatable {
        public let speaker: String
        public let text: String
        /// Session-relative speech time in seconds.
        public let at: TimeInterval?

        public init(speaker: String, text: String, at: TimeInterval? = nil) {
            self.speaker = speaker
            self.text = text
            self.at = at
        }
    }

    public struct Attempt: Sendable, Equatable {
        public let id: Int
        /// Zero-based, among the parseable records of `coaching-attempts.jsonl`.
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

        /// Whether the turn was committed to session history.
        public var isCommitted: Bool {
            outcome == "spoke" || outcome == "silent_by_model"
        }
    }

    public enum SpeakDetail: Sendable, Equatable {
        case noSpeakCall
        /// The speak call's `detail` is null or absent.
        case none
        case present(String)

        public var fences: [ReplyDetail.Fence] {
            guard case .present(let markdown) = self else { return [] }
            return ReplyDetail.fences(in: markdown)
        }
    }

    public struct FunctionCall: Sendable, Equatable {
        public let callID: String
        public let name: String
        /// Raw JSON string.
        public let arguments: String

        public init(callID: String, name: String, arguments: String) {
            self.callID = callID
            self.name = name
            self.arguments = arguments
        }
    }

    public struct TrafficRecord: Sendable, Equatable {
        /// Zero-based, counting parseable records only.
        public let index: Int
        /// `coach` or `summarizer`.
        public let tag: String
        /// `coach_attempt.id`; nil for a request made outside a coaching attempt.
        public let attemptID: Int?
        public let sourceTrigger: String?
        public let status: Int?
        public let error: String?
        /// `BrainProvider` raw value; nil when the record names none.
        public let provider: String?
        public let instructions: String?
        /// `request.tools[].name`, in order.
        public let declaredToolNames: [String]
        /// A string choice itself, or the kind of an object choice (`allowed_tools`, `function`).
        public let toolChoiceType: String?
        /// Calls replayed in the request, in order.
        public let replayedFunctionCalls: [FunctionCall]
        /// Ids of the call results replayed in the request, in order.
        public let replayedFunctionOutputCallIDs: [String]
        /// Sorted property names of the declared `speak` tool; nil when none was declared.
        public let speakParameters: [String]?
        public let speakDetail: SpeakDetail
        public let usage: RecordedExchange.Usage?
    }

    public let activity: [ActivityRow]
    /// Ordered by started record.
    public let attempts: [Attempt]
    public let traffic: [TrafficRecord]
    public let debugLines: [String]
    public let healthState: String?
    /// Unparseable non-blank lines across the activity, attempts, and traffic files.
    public let malformedRecordCount: Int
    /// For each Activity row, by index, the index into `attempts` it was attributed to.
    private let rowAttempts: [Int?]

    /// A missing file reads as empty (health as nil). Throws only when the folder name carries no
    /// date stamp.
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

    /// `sessionDate` is the session start; it dates the attempts' local clock stamps.
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

    public func rows(in attempt: Attempt) -> [ActivityRow] {
        guard let target = attempts.firstIndex(where: {
            $0.startedRecordIndex == attempt.startedRecordIndex
        }) else { return [] }
        return activity.filter { rowAttempts[$0.index] == target }
    }

    public func traffic(for attempt: Attempt) -> [TrafficRecord] {
        traffic.filter { $0.tag == "coach" && $0.attemptID == attempt.id }
    }

    /// CLI runtimes report a timeout in words; the OpenAI client records only its error code, and a
    /// URL timeout is -1001.
    public func failedOnProviderStall(_ attempt: Attempt) -> Bool {
        guard attempt.outcome == "brain_error",
              let error = traffic(for: attempt).last(where: { $0.error != nil })?.error else {
            return false
        }
        return error.localizedCaseInsensitiveContains("timed out")
            || error.contains("error_code=\(NSURLErrorTimedOut)")
    }

    /// The attempt plus the `pending_work` retries its provider stalls caused. Any other failure,
    /// or a commit, ends the chain, so `pending_work` that batches later speech is never absorbed.
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

    /// A failed attempt's observations carry into its retry, but its capability loads are discarded
    /// with it, so its load rows are left out.
    public func rows(inChain chain: [Attempt]) -> [ActivityRow] {
        chain.flatMap { attempt in
            rows(in: attempt).filter { attempt.isCommitted || $0.loadedCapability == nil }
        }
    }

    public func debugLines(containing needle: String) -> [String] {
        debugLines.filter { $0.contains(needle) }
    }

    /// A load row is written when the load happens, but the loaded set is kept only if its attempt
    /// commits, so uniqueness and order checks belong over this list.
    public var committedLoads: [LoadedCapability] {
        activity.compactMap { row in
            guard let capability = row.loadedCapability,
                  let attemptIndex = rowAttempts[row.index],
                  attempts[attemptIndex].isCommitted
            else { return nil }
            return capability
        }
    }

    /// Rows carry no attempt id, so they join by time. Attempt stamps are whole seconds, so
    /// adjacent attempts can share one; rows are walked in file order behind a cursor, and a
    /// terminal row moves the cursor past its attempt. Rows outside every attempt stay nil.
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
