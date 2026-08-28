import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import JarvisCore
// The real OpenAI adapter (over scripted transports) drives the scenario, so parity covers the
// adapter's classification and traffic recording feeding the route — not a fake's imitation.
import JarvisBrainProviders

/// Drives one fixed, fully deterministic coaching scenario and captures everything optional
/// evidence must never change: terminal coaching outcomes, the provider request sequence, overlay
/// output events, and route transitions (advance, skip, exhaustion).
///
/// The scenario walks the whole route-health surface in two triggers over a three-target route:
///
/// 1. The primary target fails three temporary transport attempts and exhausts, the preflight-proven
///    unavailable middle target is skipped, and the route advances to the final target, which
///    delivers one tip (`.spoke`).
/// 2. The final target fails three temporary attempts, so the route terminally exhausts
///    (`.brainError`).
///
/// The harness is evidence-agnostic: a variant hands its observer wiring to `run` and gets back a
/// `Snapshot` to compare against the absent-evidence baseline. A later slice that adds a new
/// evidence category extends `EvidenceObservers` with an absent-by-default field rather than
/// building a new harness or editing the scenario. Everything is driven by deterministic fakes —
/// scripted transports, `ManualClock`, and a no-op attempt delay — never by wall-clock thresholds.
enum CoachingParityHarness {
    static let primaryTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5")
    static let unavailableTarget = BrainTarget(provider: .claudeCode, modelID: "claude-sonnet-5")
    static let finalTarget = BrainTarget(provider: .openAI, modelID: "gpt-5.5-mini")

    /// The optional evidence wiring for one parity variant. Every field defaults to absent so a
    /// later evidence category joins as a new field without touching existing call sites.
    struct EvidenceObservers {
        var brainTraffic: (any BrainTrafficAuditing)?
        var coachingAttempts: (any CoachingAttemptAuditing)?

        init(
            brainTraffic: (any BrainTrafficAuditing)? = nil,
            coachingAttempts: (any CoachingAttemptAuditing)? = nil
        ) {
            self.brainTraffic = brainTraffic
            self.coachingAttempts = coachingAttempts
        }
    }

    /// One route-health event as the App edge would observe it. Failure detail stays out: raw
    /// provider errors are diagnostics, never product behavior, so parity compares target identity.
    enum RouteTransition: Equatable {
        case advanced(from: BrainTarget, to: BrainTarget)
        case skipped(BrainTarget)
        case exhausted(BrainTarget)
    }

    /// One `render` call as the overlay port received it.
    struct OverlayEvent: Equatable {
        let lines: [String]
        let perLineSeconds: [TimeInterval]
    }

    /// The complete observable coaching behavior of one scenario run. Two variants behave
    /// identically exactly when their snapshots are equal.
    struct Snapshot: Equatable {
        let outcomes: [TurnOutcome]
        let providerRequests: [Data]
        let overlayEvents: [OverlayEvent]
        let routeTransitions: [RouteTransition]
    }

    static func run(observers: EvidenceObservers = EvidenceObservers()) async -> Snapshot {
        let requests = RequestCapture()
        let transitions = TransitionCapture()
        let transportFailure = NSError(
            domain: "coaching-parity", code: 503,
            userInfo: [NSLocalizedDescriptionKey: "injected transport failure"])

        let primary = OpenAIBrainClient(
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
        let final = OpenAIBrainClient(
            apiKey: "parity-key",
            model: finalTarget.modelID,
            traffic: observers.brainTraffic,
            send: { request in
                try requests.append(request)
                guard finalCalls.next() == 1 else { throw transportFailure }
                return (
                    speakResponse,
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
                        detail: "preflight-proven unavailable"),
                    ConfiguredBrainTarget(target: finalTarget, brain: final),
                ],
                onAdvanced: { transitions.append(.advanced(from: $0, to: $1)) },
                onSkipped: { transitions.append(.skipped($0)) },
                onExhausted: { target, _ in transitions.append(.exhausted(target)) }),
            screen: FakeScreen(),
            overlay: overlay,
            clock: ManualClock(),
            coachingAttempts: observers.coachingAttempts,
            automaticAttemptDelay: { _ in },
            activityLog: ActivityLog())

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

/// Captures every provider request body in send order, re-serialized with sorted keys so two runs
/// produce byte-comparable data. `@unchecked Sendable`: the lock guards the captured requests.
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

/// Records route transitions in delivery order. `@unchecked Sendable`: the lock guards the
/// recorded events, appended from the driver's main-actor callbacks and read after the run.
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

/// Serial call counter for the succeed-once-then-fail transport script. `@unchecked Sendable`: the
/// lock guards the count.
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
