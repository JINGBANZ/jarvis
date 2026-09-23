import Foundation
import Testing
import JarvisCore
@testable import JarvisBrainProviders

@Suite struct BrainClientFactoryTests {
    /// The coach's request, then the summarizer's.
    func requests(
        for target: BrainTarget,
        keys: [Credential: String] = [.openAIAPIKey: "sk-openai"],
        effort: ReasoningEffort = .none
    ) async throws -> (coach: URLRequest, summarizer: URLRequest) {
        let captured = CapturedRequests()
        let factory = BrainClientFactory(
            keys: keys,
            proxyEndpoint: .init(baseURL: URL(string: "http://127.0.0.1:4555")!, key: "launch-key"),
            traffic: nil,
            send: { request in
                captured.append(request)
                let reply = request.url?.path.hasSuffix("/v1/messages") == true
                    ? #"{"type":"message","content":[],"stop_reason":"end_turn"}"#
                    : #"{"output":[]}"#
                return (Data(reply.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            })
        let clients = factory.makeClients(for: target, effort: effort)
        _ = try await clients.coach.respond(
            messages: [.user("hi")], tools: coachTools, toolChoice: .required)
        _ = try await clients.summarizer.respond(messages: [.user("summarize")], tools: [])
        let sent = captured.values
        try #require(sent.count == 2)
        return (sent[0], sent[1])
    }

    func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    @Test func openAITargetsCallOpenAIWithTheSavedKey() async throws {
        let sent = try await requests(for: BrainTarget(provider: .openAI, modelID: "gpt-6-astra"))
        #expect(sent.coach.url == BrainProviderDescriptor.openAIResponsesEndpoint)
        #expect(sent.coach.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai")
        #expect(try body(sent.coach)["model"] as? String == "gpt-6-astra")
        #expect((try body(sent.coach)["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(try body(sent.coach)["store"] as? Bool == true)
        #expect(sent.coach.timeoutInterval == BrainWorkloadTimeout.liveCoaching)
        #expect(try body(sent.summarizer)["model"] as? String == "gpt-5.4-mini")
        #expect(sent.summarizer.timeoutInterval == BrainWorkloadTimeout.historyCompaction)
    }

    @Test func subscriptionTargetsCallTheHelperWithTheLaunchKey() async throws {
        let codex = try await requests(
            for: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"))
        #expect(codex.coach.url?.absoluteString == "http://127.0.0.1:4555/v1/responses")
        #expect(codex.coach.value(forHTTPHeaderField: "Authorization") == "Bearer launch-key")
        #expect(try body(codex.coach)["store"] as? Bool == false)
        #expect(try body(codex.coach)["tool_choice"] as? String == "required")
        #expect(try body(codex.summarizer)["model"] as? String == "gpt-5.5")
    }

    /// Claude takes Anthropic's own route on the helper, on the coach and the summarizer alike.
    @Test func claudeTargetsCallTheHelpersMessagesRoute() async throws {
        let claude = try await requests(
            for: BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"))
        #expect(claude.coach.url?.absoluteString == "http://127.0.0.1:4555/v1/messages")
        #expect(claude.coach.value(forHTTPHeaderField: "Authorization") == "Bearer launch-key")
        #expect(claude.coach.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let coach = try body(claude.coach)
        #expect(coach["model"] as? String == "claude-opus-5")
        #expect(coach["store"] == nil && coach["strict"] == nil)
        let choice = coach["tool_choice"] as? [String: Any]
        #expect(choice?["type"] as? String == "auto")
        #expect(choice?["disable_parallel_tool_use"] as? Bool == true)
        #expect((coach["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        #expect((coach["output_config"] as? [String: Any])?["effort"] as? String == "low")   // the floor
        #expect(coach["max_tokens"] as? Int == ReasoningEffort.low.maxOutputTokens)

        #expect(claude.summarizer.url?.absoluteString == "http://127.0.0.1:4555/v1/messages")
        let summarizer = try body(claude.summarizer)
        #expect(summarizer["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(summarizer["tools"] == nil && summarizer["tool_choice"] == nil)
        #expect(summarizer["thinking"] == nil && summarizer["output_config"] == nil)
        #expect(summarizer["max_tokens"] as? Int == 2_048)
    }

    @Test func geminiTargetsCallGoogleWithTheGeminiKey() async throws {
        let sent = try await requests(
            for: BrainTarget(provider: .gemini, modelID: "gemini-3.8-flash"),
            keys: [.openAIAPIKey: "sk-openai", .geminiAPIKey: "AIzaTestKey"])
        #expect(sent.coach.url == BrainProviderDescriptor.geminiInteractionsEndpoint)
        #expect(sent.coach.value(forHTTPHeaderField: "x-goog-api-key") == "AIzaTestKey")
        #expect(sent.coach.value(forHTTPHeaderField: "Authorization") == nil)
        let config = try body(sent.coach)["generation_config"] as? [String: Any]
        #expect(config?["thinking_level"] as? String == "low")   // 3.8 rejects `minimal`
        #expect(try body(sent.summarizer)["model"] as? String == "gemini-3.5-flash-lite")
        #expect(try body(sent.summarizer)["tools"] == nil)
    }
}
