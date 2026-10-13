#if JARVIS_LIVE_E2E
import Foundation

public actor LiveE2ECacheBudget {
    public enum Failure: Error, CustomStringConvertible {
        case exhausted(String)

        public var description: String {
            switch self {
            case .exhausted(let reason): "Live cache test budget exhausted: \(reason)"
            }
        }
    }

    public static let maximumRequests = 24
    public static let maximumDuration: TimeInterval = 600
    public static let maximumOutputTokens = 2_048
    public static let maximumReservedCoachCost = 3.0
    private let deadline: Date
    private var requests = 0
    private var reservedCost = 0.0

    public init(startedAt: Date = Date()) {
        deadline = startedAt.addingTimeInterval(Self.maximumDuration)
    }

    public func reserve(inputBytes: Int, now: Date = Date()) throws {
        guard now < deadline else { throw Failure.exhausted("ten-minute deadline") }
        guard requests < Self.maximumRequests else { throw Failure.exhausted("24 provider requests") }
        guard inputBytes > 0, inputBytes <= 200_000 else {
            throw Failure.exhausted("request body must contain 1...200000 bytes")
        }
        // Reserve cache-write pricing for every visible byte plus hidden-input allowance:
        // https://developers.openai.com/api/docs/models/gpt-6.1-sol
        let reservation = Double(inputBytes + 4_096) * 2.5 / 1_000_000
            + Double(Self.maximumOutputTokens) * 10 / 1_000_000
        guard reservedCost + reservation <= Self.maximumReservedCoachCost else {
            throw Failure.exhausted("three-dollar standard-tier coaching reservation")
        }
        requests += 1
        reservedCost += reservation
    }
}
#endif
