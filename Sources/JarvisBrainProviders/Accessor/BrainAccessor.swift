import Foundation
import JarvisCore
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on non-Darwin (Core tests on Linux)
#endif

/// The one HTTP transport every brain target uses; the provider's descriptor picks the auth header,
/// the wire format, and the failure table.
public struct BrainAccessor: BrainClient, Sendable {
    public typealias Sender = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse?)

    private let provider: BrainProvider
    private let apiKey: String
    private let endpoint: URL
    private let timeout: TimeInterval
    private let toolChoicePolicy: ToolChoicePolicy
    private let wire: any BrainWireFormat
    private let send: Sender?
    private let traffic: (any BrainTrafficAuditing)?
    private let trafficTag: String

    public init(provider: BrainProvider = .openAI,
                apiKey: String,
                model: String,
                reasoningEffort: String = Defaults.Brain.effort.rawValue,
                endpoint: URL = BrainProviderDescriptor.openAIResponsesEndpoint,
                timeout: TimeInterval = BrainWorkloadTimeout.liveCoaching,
                // Reasoning plus output budget: it must track the effort or the run truncates.
                maxOutputTokens: Int = Defaults.Brain.effort.maxOutputTokens,
                toolChoicePolicy: ToolChoicePolicy = .providerEnforced,
                minimumReasoningEffort: ReasoningEffort? = nil,
                traffic: (any BrainTrafficAuditing)? = nil,
                trafficTag: String = "coach",
                send: Sender? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        // Raise to the floor without rewriting the user's shared preference, which other models may
        // still use to disable reasoning.
        let floor = [minimumReasoningEffort,
                     BrainModelCatalog.model(id: model, for: provider)?.reasoningEffortFloor]
            .compactMap { $0 }.max()
        var effort = reasoningEffort
        var cap = maxOutputTokens
        if let floor, let selected = ReasoningEffort(rawValue: reasoningEffort), selected < floor {
            effort = floor.rawValue
            cap = max(maxOutputTokens, floor.maxOutputTokens)
        }
        switch provider.descriptor.wire {
        case .responses:
            wire = ResponsesWireFormat(
                model: model, reasoningEffort: effort, maxOutputTokens: cap,
                store: !provider.servedByLocalProxy)
        }
        self.endpoint = endpoint
        self.timeout = timeout
        self.toolChoicePolicy = toolChoicePolicy
        self.traffic = traffic
        self.trafficTag = trafficTag
        self.send = send
    }

    public func respond(messages: [ChatMessage], tools: [ToolDef],
                        toolChoice: ToolChoice) async throws -> BrainResponse {
        do {
            return try await performRequest(
                messages: messages, tools: tools, toolChoice: toolChoice)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            // One round trip with nothing ready behind it: a refused connection is unreachable.
            throw ProviderFailure(unclassified: error, source: .brain(provider), stage: .request)
        }
    }

    private func performRequest(messages: [ChatMessage], tools: [ToolDef],
                                toolChoice: ToolChoice) async throws -> BrainResponse {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch provider.descriptor.auth {
        case .bearer: request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let resolved = toolChoicePolicy.resolve(tools: tools, choice: toolChoice)
        let body = try wire.encode(messages: messages, tools: resolved.tools, toolChoice: resolved.choice)
        request.httpBody = body

        // Exactly one request, never retried: a fresh attempt should include newer transcript.
        let started = Date()
        let delegate = BrainRequestDelegate()
        let data: Data
        let http: HTTPURLResponse?
        do {
            if let send {
                (data, http) = try await send(request)
            } else {
                let result = try await URLSession.shared.data(for: request, delegate: delegate)
                (data, http) = (result.0, result.1 as? HTTPURLResponse)
            }
        } catch {
            traffic?.record(tag: trafficTag, provider: provider, request: body, response: nil, status: nil,
                            latencyMs: Self.elapsedMs(since: started),
                            error: BrainRequestDelegate.errorSummary(error), phases: delegate.phases)
            throw error
        }
        let status = http?.statusCode ?? 0
        traffic?.record(tag: trafficTag, provider: provider, request: body, response: data, status: status,
                        latencyMs: Self.elapsedMs(since: started), phases: delegate.phases)
        guard (200..<300).contains(status) else {
            throw failure(httpStatus: status, body: data)
        }
        return try wire.decode(data)
    }

    private func failure(httpStatus: Int, body: Data) -> ProviderFailure {
        switch provider.descriptor.failureTable {
        case .openAI:
            OpenAIFailureClassifier.classify(
                httpStatus: httpStatus, body: body, source: .brain(provider), stage: .request)
        }
    }

    private static func elapsedMs(since started: Date) -> Int {
        Int(Date().timeIntervalSince(started) * 1000)
    }
}
