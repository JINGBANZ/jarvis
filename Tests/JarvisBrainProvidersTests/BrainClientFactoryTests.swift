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
                return (Data(#"{"output":[]}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
            })
        let clients = factory.makeClients(for: target, effort: effort)
        _ = try await clients.coach.respond(
            messages: [.user("hi")], tools: coachTools(detailEnabled: false), toolChoice: .required)
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
        let claude = try await requests(
            for: BrainTarget(provider: .claudeSubscription, modelID: "claude-opus-5"))
        #expect(claude.coach.url?.absoluteString == "http://127.0.0.1:4555/v1/responses")
        #expect(claude.coach.value(forHTTPHeaderField: "Authorization") == "Bearer launch-key")
        #expect(try body(claude.coach)["store"] as? Bool == false)
        #expect(try body(claude.coach)["tool_choice"] as? String == "auto")
        #expect((try body(claude.coach)["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(try body(claude.summarizer)["model"] as? String == "claude-haiku-4-5-20251001")

        let codex = try await requests(
            for: BrainTarget(provider: .codexSubscription, modelID: "gpt-5.5"))
        #expect(try body(codex.coach)["tool_choice"] as? String == "required")
        #expect(try body(codex.summarizer)["model"] as? String == "gpt-5.5")
    }
}
