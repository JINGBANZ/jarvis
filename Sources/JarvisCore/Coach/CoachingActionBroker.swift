import Foundation

/// The transport-independent authority for one coaching attempt.
///
/// Native API function calls and MCP calls both enter this actor. An attempt may capture the screen
/// at most once. `speak` / `stay_silent` stage exactly one terminal decision; only `commit()` turns
/// that staged decision into a host-consumable effect.
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

    public struct CaptureObservation: Sendable, Equatable {
        public let callID: String
        public let snapshot: ScreenSnapshot?

        public init(callID: String, snapshot: ScreenSnapshot?) {
            self.callID = callID
            self.snapshot = snapshot
        }
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidated
        case concurrentCall
        case unknownTool(String)
        case toolNotAllowed(String)
        case malformedArguments(String)
        case duplicateCapture
        case duplicateTerminal
        case captureAfterTerminal
        case forcedTerminalMismatch(expected: String, actual: String)
        case multipleCallsInResponse
        case returnedCallMismatch
        case missingTerminal
        case duplicateCommit

        public var errorDescription: String? {
            switch self {
            case .invalidated:
                return "coaching action attempt was invalidated"
            case .concurrentCall:
                return "coaching actions must be called serially"
            case .unknownTool(let name):
                return "unknown coaching action '\(name)'"
            case .toolNotAllowed(let name):
                return "coaching action '\(name)' is not allowed in this attempt"
            case .malformedArguments(let name):
                return "malformed arguments for coaching action '\(name)'"
            case .duplicateCapture:
                return "coaching attempt requested more than one screen capture"
            case .duplicateTerminal:
                return "coaching attempt produced more than one terminal action"
            case .captureAfterTerminal:
                return "capture_screen was called after a terminal action"
            case .forcedTerminalMismatch(let expected, let actual):
                return "coaching attempt required '\(expected)' but received '\(actual)'"
            case .multipleCallsInResponse:
                return "provider returned multiple coaching actions in one response"
            case .returnedCallMismatch:
                return "provider returned inconsistent raw and parsed coaching actions"
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

    private struct CompletedCapture {
        let requestID: String
        let snapshot: ScreenSnapshot?
    }

    private let capture: Capture
    private let captureObserver: CaptureObserver
    private let allowedToolNames: Set<String>
    private let requiredTerminalToolName: String?
    private let validity = Validity()
    private var phase: Phase = .open
    private var completedCapture: CompletedCapture?
    private var captureAcknowledged = false

    public init(
        identity: Identity,
        capture: @escaping @Sendable () async -> ScreenSnapshot?,
        captureObserver: @escaping @Sendable (ScreenSnapshot?) -> Void = { _ in },
        allowedToolNames: Set<String> = Set(coachTools.map(\.name)),
        requiredTerminalToolName: String? = nil
    ) {
        self.identity = identity
        self.capture = capture
        self.captureObserver = captureObserver
        self.allowedToolNames = allowedToolNames
        self.requiredTerminalToolName = requiredTerminalToolName
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
        guard coachTools.contains(where: { $0.name == name }) else {
            throw fail(.unknownTool(name))
        }
        guard allowedToolNames.contains(name) else {
            throw fail(.toolNotAllowed(name))
        }

        let decoded: [String: Any]
        do {
            decoded = try Self.argumentsObject(argumentsJSON)
        } catch {
            throw fail(.malformedArguments(name))
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
            guard completedCapture == nil else {
                throw fail(.duplicateCapture)
            }
            phase = .capturing(requestID: requestID)
            let snapshot = await capture()
            try ensureCurrent()
            guard case .capturing(let activeRequestID) = phase,
                  activeRequestID == requestID else {
                throw fail(.concurrentCall)
            }
            phase = .open
            completedCapture = CompletedCapture(requestID: requestID, snapshot: snapshot)
            return .capture(snapshot)

        case speakTool.name:
            let lines: [String]
            do {
                lines = try Self.speakLines(decoded, toolName: name)
            } catch {
                throw fail(.malformedArguments(name))
            }
            return try stage(.speak(callID: requestID, lines: lines))

        case staySilentTool.name:
            guard decoded.isEmpty else {
                throw fail(.malformedArguments(name))
            }
            return try stage(.staySilent(callID: requestID))

        default:
            throw fail(.unknownTool(name))
        }
    }

    public func rejectMultipleCallsInResponse() throws {
        try ensureCurrent()
        throw fail(.multipleCallsInResponse)
    }

    public func rejectReturnedCallMismatch() throws {
        try ensureCurrent()
        throw fail(.returnedCallMismatch)
    }

    /// Records a capture only after its transport has accepted the result for delivery. Repeated
    /// acknowledgements are harmless.
    @discardableResult
    public func acknowledgeCaptureDelivery(requestID: String) throws -> Bool {
        try ensureCurrent()
        guard let completedCapture,
              completedCapture.requestID == requestID else {
            return false
        }
        guard !captureAcknowledged else {
            return true
        }
        let snapshot = completedCapture.snapshot
        captureObserver(snapshot)
        captureAcknowledged = true
        return true
    }

    /// Called after the provider reaches its successful completion boundary. That is an ordinary
    /// complete response for native/Claude paths or a host-proven terminal delivery for Codex.
    /// This verifies liveness without committing an effect; `CoachDriver` remains the only commit
    /// authority.
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

    public func captureObservation() -> CaptureObservation? {
        guard captureAcknowledged, let completedCapture else { return nil }
        return CaptureObservation(
            callID: completedCapture.requestID,
            snapshot: completedCapture.snapshot)
    }

    private func stage(_ decision: TerminalDecision) throws -> ToolResult {
        // A terminal that races ahead of the capture result could not have used that evidence. The
        // native route acknowledges before request two; MCP acknowledges only after its SDK
        // transport writes the capture response.
        if completedCapture != nil, !captureAcknowledged {
            throw fail(.concurrentCall)
        }
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
        phase = .terminalStaged(decision)
        return .terminalAccepted
    }

    private func ensureCurrent() throws {
        try Task.checkCancellation()
        guard validity.isActive else { throw Failure.invalidated }
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
