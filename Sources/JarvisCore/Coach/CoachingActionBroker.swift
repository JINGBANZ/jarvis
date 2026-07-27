import Foundation

/// The transport-independent authority for one coaching attempt.
///
/// Native API function calls and MCP calls both enter this actor. Captures may repeat serially within
/// the attempt's action bound. `speak` / `stay_silent` stage exactly one terminal decision; only
/// `commit()` turns that staged decision into a host-consumable effect.
public actor CoachingActionBroker {
    public struct Identity: Sendable, Equatable, Codable {
        public let attemptID: UUID
        public let configurationRevision: UInt

        public init(attemptID: UUID = UUID(), configurationRevision: UInt) {
            self.attemptID = attemptID
            self.configurationRevision = configurationRevision
        }
    }

    public enum TerminalDecision: Sendable, Equatable {
        case speak(callID: String, lines: [String])
        case staySilent(callID: String)

        public var invocation: ToolInvocation {
            switch self {
            case .speak(let callID, let lines):
                return .speak(callId: callID, lines: lines)
            case .staySilent(let callID):
                return .staySilent(callId: callID)
            }
        }

        public var rawToolCall: RawToolCall {
            switch self {
            case .speak(let callID, let lines):
                let data = try? JSONSerialization.data(
                    withJSONObject: ["lines": lines],
                    options: [.sortedKeys])
                return RawToolCall(
                    id: callID,
                    name: speakTool.name,
                    argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            case .staySilent(let callID):
                return RawToolCall(id: callID, name: staySilentTool.name, argumentsJSON: "{}")
            }
        }
    }

    public enum ToolResult: Sendable, Equatable {
        case capture(ScreenSnapshot?)
        case terminalAccepted
    }

    public enum Event: Sendable, Equatable {
        case captured(callID: String, snapshot: ScreenSnapshot?)
        case terminal(TerminalDecision)
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidated
        case staleAttempt
        case concurrentCall
        case replayedRequest(String)
        case unknownTool(String)
        case malformedArguments(String)
        case duplicateTerminal
        case captureAfterTerminal
        case forcedTerminalMismatch(expected: String, actual: String)
        case actionLimitExceeded(Int)
        case multipleCallsInResponse
        case missingTerminal
        case duplicateCommit

        public var errorDescription: String? {
            switch self {
            case .invalidated:
                return "coaching action attempt was invalidated"
            case .staleAttempt:
                return "coaching action belongs to a stale attempt"
            case .concurrentCall:
                return "coaching actions must be called serially"
            case .replayedRequest(let requestID):
                return "coaching action request \(requestID) was replayed with different data"
            case .unknownTool(let name):
                return "unknown coaching action '\(name)'"
            case .malformedArguments(let name):
                return "malformed arguments for coaching action '\(name)'"
            case .duplicateTerminal:
                return "coaching attempt produced more than one terminal action"
            case .captureAfterTerminal:
                return "capture_screen was called after a terminal action"
            case .forcedTerminalMismatch(let expected, let actual):
                return "coaching attempt required '\(expected)' but received '\(actual)'"
            case .actionLimitExceeded(let limit):
                return "coaching attempt exceeded its \(limit)-action limit"
            case .multipleCallsInResponse:
                return "provider returned multiple coaching actions in one response"
            case .missingTerminal:
                return "provider completed without a terminal coaching action"
            case .duplicateCommit:
                return "terminal coaching action was committed more than once"
            }
        }
    }

    public nonisolated let identity: Identity

    private typealias Capture = @Sendable () async -> ScreenSnapshot?
    private typealias CaptureObserver = @Sendable (ScreenSnapshot?) -> Void

    /// A synchronous cancellation bit shared with nonisolated teardown; `lock` protects all state.
    private final class Validity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true

        var isActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }

        func invalidate() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    private enum Phase {
        case open
        case capturing(requestID: String)
        case terminalStaged(TerminalDecision)
        case committed(TerminalDecision)
        case failed(Failure)
    }

    private struct CachedResult {
        let fingerprint: String
        let result: ToolResult
    }

    private let capture: Capture
    private let captureObserver: CaptureObserver
    private let isCurrentAttempt: @Sendable () -> Bool
    private let requiredTerminalToolName: String?
    private let maximumActionCalls: Int
    private let validity = Validity()
    private var phase: Phase = .open
    private var cache: [String: CachedResult] = [:]
    private var recordedEvents: [Event] = []
    private var actionCallCount = 0

    public init(
        identity: Identity,
        capture: @escaping @Sendable () async -> ScreenSnapshot?,
        captureObserver: @escaping @Sendable (ScreenSnapshot?) -> Void = { _ in },
        isCurrentAttempt: @escaping @Sendable () -> Bool = { true },
        requiredTerminalToolName: String? = nil,
        maximumActionCalls: Int = 4
    ) {
        precondition(maximumActionCalls > 0)
        self.identity = identity
        self.capture = capture
        self.captureObserver = captureObserver
        self.isCurrentAttempt = isCurrentAttempt
        self.requiredTerminalToolName = requiredTerminalToolName
        self.maximumActionCalls = maximumActionCalls
    }

    /// Synchronous so Stop/configuration changes can revoke a bridge from cancellation handlers.
    public nonisolated func invalidate() {
        validity.invalidate()
    }

    public func call(
        requestID: String,
        name: String,
        argumentsJSON: String
    ) async throws -> ToolResult {
        try ensureCurrent()
        guard !requestID.isEmpty else {
            throw fail(.malformedArguments(name))
        }

        let decoded: [String: Any]
        let canonical: String
        do {
            decoded = try Self.argumentsObject(argumentsJSON)
            canonical = try Self.canonicalJSON(decoded)
        } catch {
            throw fail(.malformedArguments(name))
        }
        let fingerprint = "\(name)\u{0}\(canonical)"

        if let cached = cache[requestID] {
            guard cached.fingerprint == fingerprint else {
                throw fail(.replayedRequest(requestID))
            }
            return cached.result
        }

        switch phase {
        case .capturing:
            throw fail(.concurrentCall)
        case .failed(let failure):
            throw failure
        case .committed:
            throw Failure.duplicateCommit
        case .open, .terminalStaged:
            break
        }

        switch name {
        case captureScreenTool.name:
            guard decoded.isEmpty else {
                throw fail(.malformedArguments(name))
            }
            guard case .open = phase else {
                throw fail(.captureAfterTerminal)
            }
            try reserveActionCall()
            phase = .capturing(requestID: requestID)
            let snapshot = await capture()
            try ensureCurrent()
            guard case .capturing(let activeRequestID) = phase,
                  activeRequestID == requestID else {
                throw fail(.concurrentCall)
            }
            phase = .open
            captureObserver(snapshot)
            let result = ToolResult.capture(snapshot)
            cache[requestID] = CachedResult(fingerprint: fingerprint, result: result)
            recordedEvents.append(.captured(callID: requestID, snapshot: snapshot))
            return result

        case speakTool.name:
            let lines = try Self.speakLines(decoded, toolName: name)
            return try stage(
                .speak(callID: requestID, lines: lines),
                requestID: requestID,
                fingerprint: fingerprint)

        case staySilentTool.name:
            guard decoded.isEmpty else {
                throw fail(.malformedArguments(name))
            }
            return try stage(
                .staySilent(callID: requestID),
                requestID: requestID,
                fingerprint: fingerprint)

        default:
            throw fail(.unknownTool(name))
        }
    }

    public func submit(_ invocation: ToolInvocation) async throws -> ToolResult {
        switch invocation {
        case .captureScreen(let callID):
            return try await call(
                requestID: callID,
                name: captureScreenTool.name,
                argumentsJSON: "{}")
        case .speak(let callID, let lines):
            let data = try JSONSerialization.data(
                withJSONObject: ["lines": lines],
                options: [.sortedKeys])
            return try await call(
                requestID: callID,
                name: speakTool.name,
                argumentsJSON: String(decoding: data, as: UTF8.self))
        case .staySilent(let callID):
            return try await call(
                requestID: callID,
                name: staySilentTool.name,
                argumentsJSON: "{}")
        }
    }

    public func rejectMultipleCallsInResponse() throws {
        try ensureCurrent()
        throw fail(.multipleCallsInResponse)
    }

    /// Called after an MCP agent process exits cleanly. It verifies liveness without committing an
    /// effect; `CoachDriver` remains the only commit authority.
    public func requireTerminal() throws -> TerminalDecision {
        try ensureCurrent()
        switch phase {
        case .terminalStaged(let decision), .committed(let decision):
            return decision
        case .failed(let failure):
            throw failure
        case .open, .capturing:
            throw fail(.missingTerminal)
        }
    }

    public func commit() throws -> TerminalDecision {
        try ensureCurrent()
        switch phase {
        case .terminalStaged(let decision):
            phase = .committed(decision)
            return decision
        case .committed:
            throw Failure.duplicateCommit
        case .failed(let failure):
            throw failure
        case .open, .capturing:
            throw fail(.missingTerminal)
        }
    }

    public func events() -> [Event] {
        recordedEvents
    }

    public func latestCapture() -> ScreenSnapshot? {
        for event in recordedEvents.reversed() {
            if case .captured(_, let snapshot) = event {
                return snapshot
            }
        }
        return nil
    }

    public func hasCaptureAttempt() -> Bool {
        recordedEvents.contains {
            if case .captured = $0 { return true }
            return false
        }
    }

    private func stage(
        _ decision: TerminalDecision,
        requestID: String,
        fingerprint: String
    ) throws -> ToolResult {
        let actualToolName: String
        switch decision {
        case .speak:
            actualToolName = speakTool.name
        case .staySilent:
            actualToolName = staySilentTool.name
        }
        if let requiredTerminalToolName,
           requiredTerminalToolName != actualToolName {
            throw fail(.forcedTerminalMismatch(
                expected: requiredTerminalToolName,
                actual: actualToolName))
        }
        guard case .open = phase else {
            throw fail(.duplicateTerminal)
        }
        try reserveActionCall()
        phase = .terminalStaged(decision)
        let result = ToolResult.terminalAccepted
        cache[requestID] = CachedResult(fingerprint: fingerprint, result: result)
        recordedEvents.append(.terminal(decision))
        return result
    }

    private func reserveActionCall() throws {
        guard actionCallCount < maximumActionCalls else {
            throw fail(.actionLimitExceeded(maximumActionCalls))
        }
        actionCallCount += 1
    }

    private func ensureCurrent() throws {
        try Task.checkCancellation()
        guard validity.isActive else { throw Failure.invalidated }
        guard isCurrentAttempt() else { throw Failure.staleAttempt }
    }

    @discardableResult
    private func fail(_ failure: Failure) -> Failure {
        phase = .failed(failure)
        return failure
    }

    private static func argumentsObject(_ json: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(
            with: Data(json.utf8)) as? [String: Any] else {
            throw Failure.malformedArguments("unknown")
        }
        return object
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func speakLines(
        _ object: [String: Any],
        toolName: String
    ) throws -> [String] {
        guard Set(object.keys) == ["lines"],
              let rawLines = object["lines"] as? [String] else {
            throw Failure.malformedArguments(toolName)
        }
        let lines = rawLines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !lines.isEmpty else {
            throw Failure.malformedArguments(toolName)
        }
        return lines
    }
}
