import Foundation
import Testing
@testable import JarvisCore

@Suite("Live cache request budget")
struct LiveE2ECacheBudgetTests {
    @Test("requests stop at the cap without a retry allowance", arguments: [BrainProvider.codexSubscription, .openAI])
    func requestLimit(provider: BrainProvider) async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = LiveE2ECacheBudget(provider: provider, startedAt: start)
        for _ in 0..<LiveE2ECacheBudget.maximumRequests {
            try await budget.reserve(inputBytes: 1, now: start)
        }
        await #expect(throws: LiveE2ECacheBudget.Failure.self) {
            try await budget.reserve(inputBytes: 1, now: start)
        }
    }

    @Test("deadline and malformed body stop before sending another request", arguments: [BrainProvider.codexSubscription, .openAI])
    func deadlineAndBody(provider: BrainProvider) async {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = LiveE2ECacheBudget(provider: provider, startedAt: start)
        for bytes in [0, -1, 200_001] {
            await #expect(throws: LiveE2ECacheBudget.Failure.self) {
                try await budget.reserve(inputBytes: bytes, now: start)
            }
        }
        await #expect(throws: LiveE2ECacheBudget.Failure.self) {
            try await budget.reserve(inputBytes: 1, now: start.addingTimeInterval(600))
        }
    }

    @Test("paid OpenAI contexts exhaust the conservative cost reservation first")
    func spendLimit() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = LiveE2ECacheBudget(provider: .openAI, startedAt: start)
        for _ in 0..<5 {
            try await budget.reserve(inputBytes: 200_000, now: start)
        }
        await #expect(throws: LiveE2ECacheBudget.Failure.self) {
            try await budget.reserve(inputBytes: 200_000, now: start)
        }
    }

    @Test("subscription contexts have no paid API reservation")
    func subscriptionDoesNotReservePaidCost() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let budget = LiveE2ECacheBudget(provider: .codexSubscription, startedAt: start)
        for _ in 0..<LiveE2ECacheBudget.maximumRequests {
            try await budget.reserve(inputBytes: 200_000, now: start)
        }
        await #expect(throws: LiveE2ECacheBudget.Failure.self) {
            try await budget.reserve(inputBytes: 200_000, now: start)
        }
    }
}
