import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JarvisCore
// Uses the real OpenAI adapter so parity covers its failure classification and traffic recording.
import JarvisBrainProviders

/// Trigger 1: the primary fails three transport attempts, the unavailable target is skipped, and
/// the final target speaks. Trigger 2: the final target fails twice, then fails permanently.
enum CoachingParityHarness {
    static let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
    static let unavailableTarget = BrainTarget(provider: .claudeSubscription, modelID: "claude-sonnet-5")
    static let finalTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5-mini")

    struct EvidenceObservers {
        var brainTraffic: (any BrainTrafficAuditing)?
        var coachingAttempts: (any CoachingAttemptAuditing)?
        var diagnostics: FileSessionAudit?
        var activity: (any ActivityEventRecording)?

        init(
            brainTraffic: (any BrainTrafficAuditing)? = nil,
            coachingAttempts: (any CoachingAttemptAuditing)? = nil,
            diagnostics: FileSessionAudit? = nil,
            activity: (any ActivityEventRecording)? = nil
        ) {
            self.brainTraffic = brainTraffic
            self.coachingAttempts = coachingAttempts
            self.diagnostics = diagnostics
            self.activity = activity
        }
    }

    /// Omits failure detail on purpose: raw provider errors are diagnostics, not coaching behavior.
    enum RouteTransition: Equatable {
        case advanced(from: BrainTarget, to: BrainTarget)
        case skipped(BrainTarget)
        case exhausted(BrainTarget)
    }

    struct OverlayEvent: Equatable {
        let lines: [String]
        let perLineSeconds: [TimeInterval]
    }

    struct Snapshot: Equatable {
        let outcomes: [TurnOutcome]
        let providerRequests: [Data]
        let overlayEvents: [OverlayEvent]
        let routeTransitions: [RouteTransition]
    }

    static func run(observers: EvidenceObservers = EvidenceObservers()) async -> Snapshot {
        guard let diagnostics = observers.diagnostics else {
            return await runScenario(observers: observers)
        }
        return await JarvisLogAttachmentLock.withExclusiveAttachment {
            JarvisLog.attach(to: diagnostics)
            defer { JarvisLog.detach() }
            return await runScenario(observers: observers)
        }
    }

    private static func runScenario(observers: EvidenceObservers) async -> Snapshot {
        let requests = RequestCapture()
        let transitions = TransitionCapture()
        let transportFailure = NSError(
            domain: "coaching-parity", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "injected transport failure"])

        let primary = BrainAccessor(
            apiKey: "parity-key",
            model: primaryTarget.modelID,
            traffic: observers.brainTraffic,
            send: { request in
                try requests.append(request)
                throw transportFailure
            })

        let speakResponse = Data(
            #"{"status":"completed","output":[{"type":"function_call","call_id":"s1","name":"speak","arguments":"{\"lines\":[\"same tip\"]}"}]}"#.utf8)
        let finalCalls = CallCounter()
        let final = BrainAccessor(
            apiKey: "parity-key",
            model: finalTarget.modelID,
            traffic: observers.brainTraffic,
            send: { request in
                try requests.append(request)
                let call = finalCalls.next()
                if call == 4 {
                    throw ProviderFailure(source: .brain(.openAI), stage: .request, category: .unknown, disposition: .permanent, identity: .init(), message: "injected permanent failure")
                }
                guard call == 1 else { throw transportFailure }
                return (
                    chunk(speakResponse),
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil))
            })

        let overlay = FakeOverlay()
        let transcript = RollingTranscript()
        let driver = CoachDriver(
            config: .default,
            transcript: transcript,
            route: ConfiguredBrainRoute(
                targets: [
                    ConfiguredBrainTarget(target: primaryTarget, brain: primary),
                    ConfiguredBrainTarget(
                        unavailable: unavailableTarget,
                        failure: ProviderFailure(
                            source: .brain(unavailableTarget.provider), stage: .process,
                            category: .unavailable, disposition: .permanent, identity: .init(),
                            message: "preflight-proven unavailable")),
                    ConfiguredBrainTarget(target: finalTarget, brain: final),
                ],
                onAdvanced: { previous, current, _ in transitions.append(.advanced(from: previous, to: current)) },
                onSkipped: { target, _ in transitions.append(.skipped(target)) },
                onExhausted: { target, _ in transitions.append(.exhausted(target)) }),
            screen: FakeScreen(),
            overlay: overlay,
            clock: ManualClock(),
            coachingAttempts: observers.coachingAttempts,
            automaticAttemptDelay: { _ in },
            activity: observers.activity)

        var outcomes: [TurnOutcome] = []
        transcript.append(.init(speaker: .me, text: "walk the route forward", at: 1))
        outcomes.append(await driver.handleTrigger(.turnEnd))
        transcript.append(.init(speaker: .me, text: "now exhaust the final target", at: 2))
        outcomes.append(await driver.handleTrigger(.turnEnd))

        return Snapshot(
            outcomes: outcomes,
            providerRequests: requests.bodies,
            overlayEvents: zip(overlay.rendered, overlay.renderedSeconds)
                .map { OverlayEvent(lines: $0, perLineSeconds: $1) },
            routeTransitions: transitions.events)
    }
}

/// A whole-body reply as the one-chunk stream the production transport delivers it in.
private func chunk(_ data: Data) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        continuation.yield(data)
        continuation.finish()
    }
}

/// @unchecked: the lock guards `storage`. Sorted keys make two runs' bodies byte-comparable.
private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ request: URLRequest) throws {
        let object = try JSONSerialization.jsonObject(with: request.httpBody ?? Data())
        let normalized = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        lock.withLock { storage.append(normalized) }
    }

    var bodies: [Data] {
        lock.withLock { storage }
    }
}

/// @unchecked: the lock guards `storage`.
private final class TransitionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CoachingParityHarness.RouteTransition] = []

    func append(_ transition: CoachingParityHarness.RouteTransition) {
        lock.withLock { storage.append(transition) }
    }

    var events: [CoachingParityHarness.RouteTransition] {
        lock.withLock { storage }
    }
}

/// @unchecked: the lock guards `count`.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
