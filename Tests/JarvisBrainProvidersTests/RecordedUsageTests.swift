import Foundation
import Testing
@testable import JarvisBrainProviders

@Suite struct RecordedUsageTests {
    @Test func responsesInputIncludesReadsAndWrites() throws {
        let usage = try #require(RecordedExchange.read(request: nil, response: ["usage": [
            "input_tokens": 100, "input_tokens_details": ["cached_tokens": 50, "cache_write_tokens": 20],
            "output_tokens": 5,
        ]]).usage)
        #expect(usage.input == 100)
        #expect(usage.totalInput == 100)
        #expect(usage.uncachedInput == 30)
        #expect(usage.cacheRead == 50)
        #expect(usage.cacheWrite == 20)
        #expect(usage.output == 5)
    }

    @Test func messagesInputExcludesReadsAndWrites() throws {
        let usage = try #require(RecordedExchange.read(request: ["messages": []], response: ["usage": [
            "input_tokens": 30, "cache_read_input_tokens": 50, "cache_creation_input_tokens": 20,
            "output_tokens": 5,
        ]]).usage)
        #expect(usage.input == 30)
        #expect(usage.totalInput == 100)
        #expect(usage.uncachedInput == 30)
        #expect(usage.cacheRead == 50)
        #expect(usage.cacheWrite == 20)
        #expect(usage.output == 5)
    }

    @Test func missingCountersStayUnknown() throws {
        let responses = try #require(RecordedExchange.read(request: nil, response: ["usage": [
            "input_tokens": 100, "input_tokens_details": ["cached_tokens": 50],
        ]]).usage)
        #expect(responses.totalInput == 100)
        #expect(responses.cacheWrite == nil)
        #expect(responses.uncachedInput == nil)
        #expect(responses.output == nil)
        let messages = try #require(RecordedExchange.read(request: ["messages": []], response: [
            "usage": ["input_tokens": 30, "cache_read_input_tokens": 50],
        ]).usage)
        #expect(messages.totalInput == nil)
        #expect(messages.uncachedInput == 30)
        #expect(messages.cacheWrite == nil)
        #expect(messages.output == nil)
    }

    @Test func knownZeroDiffersFromMissingUsage() throws {
        #expect(RecordedExchange.read(request: nil, response: [:]).usage == nil)
        let unknown = try #require(RecordedExchange.read(request: nil, response: ["usage": [:]]).usage)
        let zero = try #require(RecordedExchange.read(request: nil, response: ["usage": [
            "input_tokens": 0, "input_tokens_details": ["cached_tokens": 0, "cache_write_tokens": 0],
            "output_tokens": 0,
        ]]).usage)
        #expect(unknown.totalInput == nil)
        #expect(unknown.cacheRead == nil)
        #expect(unknown.uncachedInput == nil)
        #expect(unknown.debugSummary.contains("cached unknown"))
        #expect(zero.totalInput == 0)
        #expect(zero.cacheRead == 0)
        #expect(zero.cacheWrite == 0)
        #expect(zero.uncachedInput == 0)
        #expect(zero.output == 0)
    }

    @Test func interactionsOutputIncludesKnownThoughtTokens() throws {
        let usage = try #require(RecordedExchange.read(request: ["generation_config": [:]], response: ["usage": [
            "total_input_tokens": 100, "total_cached_tokens": 40,
            "total_output_tokens": 10, "total_thought_tokens": 5,
        ]]).usage)
        #expect(usage.totalInput == 100)
        #expect(usage.uncachedInput == 60)
        #expect(usage.cacheWrite == nil)
        #expect(usage.output == 15)
        let partial = try #require(RecordedExchange.read(request: ["generation_config": [:]], response: [
            "usage": ["total_output_tokens": 10],
        ]).usage)
        #expect(partial.output == nil)
    }

    @Test func inconsistentOrOverflowingCountersHaveNoDerivedTotal() throws {
        let excessive = try #require(RecordedExchange.read(request: nil, response: ["usage": [
            "input_tokens": 100, "input_tokens_details": ["cached_tokens": 120, "cache_write_tokens": 0],
        ]]).usage)
        #expect(excessive.uncachedInput == nil)
        let overflow = try #require(RecordedExchange.read(request: ["messages": []], response: ["usage": [
            "input_tokens": Int.max, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 0,
        ]]).usage)
        #expect(overflow.totalInput == nil)
    }
}
