import Foundation
import JarvisCore

public struct BrainClientFactory: Sendable {
    public struct Clients: Sendable {
        public let coach: any BrainClient
        public let summarizer: any BrainClient
    }

    private let keys: [Credential: String]
    private let proxyEndpoint: LocalProxySupervisor.Endpoint?
    private let traffic: (any BrainTrafficAuditing)?
    private let send: BrainAccessor.Sender?

    public init(
        keys: [Credential: String],
        proxyEndpoint: LocalProxySupervisor.Endpoint?,
        traffic: (any BrainTrafficAuditing)?,
        send: BrainAccessor.Sender? = nil
    ) {
        self.keys = keys
        self.proxyEndpoint = proxyEndpoint
        self.traffic = traffic
        self.send = send
    }

    public func makeClients(for target: BrainTarget, effort: ReasoningEffort) -> Clients {
        let provider = target.provider
        let endpoint: URL
        let key: String
        switch provider.descriptor.access {
        case .apiKey(let credential, let url, _):
            endpoint = url
            key = keys[credential] ?? ""
        case .localProxy:
            // The app composes a helper target only after the helper answered with an endpoint.
            guard let proxyEndpoint else {
                preconditionFailure("\(provider.displayName) was composed without the helper's endpoint")
            }
            endpoint = proxyEndpoint.responsesURL
            key = proxyEndpoint.key
        }
        let summaryModel = BrainModelCatalog.summarizerModelID(for: provider)
        let coach = BrainAccessor(
            provider: provider, apiKey: key, model: target.modelID,
            reasoningEffort: effort.rawValue, endpoint: endpoint,
            timeout: BrainWorkloadTimeout.liveCoaching,
            maxOutputTokens: effort.maxOutputTokens,
            toolChoicePolicy: provider.toolChoicePolicy,
            minimumReasoningEffort: provider.reasoningEffortFloor,
            traffic: traffic, trafficTag: "coach", send: send)
        let summarizer = BrainAccessor(
            provider: provider, apiKey: key,
            model: summaryModel.isEmpty ? target.modelID : summaryModel,
            reasoningEffort: ReasoningEffort.low.rawValue, endpoint: endpoint,
            timeout: BrainWorkloadTimeout.historyCompaction, maxOutputTokens: 2_048,
            toolChoicePolicy: provider.toolChoicePolicy,
            minimumReasoningEffort: provider.reasoningEffortFloor,
            traffic: traffic, trafficTag: "summarizer", send: send)
        return Clients(coach: coach, summarizer: summarizer)
    }
}
