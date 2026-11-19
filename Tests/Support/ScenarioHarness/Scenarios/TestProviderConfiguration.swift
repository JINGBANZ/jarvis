#if JARVIS_LIVE_E2E
import Foundation
import JarvisCore

public struct TestProviderConfiguration: Decodable, Sendable {
    public let defaultProvider: BrainProvider
    public let defaultJudgeProvider: BrainProvider
    public let models: [String: String]
    public let judgeModels: [String: String]

    private enum CodingKeys: String, CodingKey {
        case defaultProvider, defaultJudgeProvider, models, judgeModels
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let providerID = try values.decode(String.self, forKey: .defaultProvider)
        let judgeID = try values.decode(String.self, forKey: .defaultJudgeProvider)
        guard let provider = BrainProvider(rawValue: providerID), let judge = BrainProvider(rawValue: judgeID) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unsupported test provider"))
        }
        defaultProvider = provider
        defaultJudgeProvider = judge
        models = try values.decode([String: String].self, forKey: .models)
        judgeModels = try values.decode([String: String].self, forKey: .judgeModels)
    }

    public static let shared: Self = {
        do {
            return try load(in: Bundle(for: Anchor.self))
        } catch {
            preconditionFailure("Invalid shared test provider configuration: \(error)")
        }
    }()

    static func load(in host: Bundle) throws -> Self {
        let installedBundle = host.resourceURL?
            .appendingPathComponent("Jarvis_JarvisScenarioHarness.bundle")
        let resources = installedBundle.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "test-providers", withExtension: "json") else {
            preconditionFailure("Missing shared test provider configuration")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    private final class Anchor: NSObject {}

    public func modelID(for provider: BrainProvider, judge: Bool = false) -> String {
        if judge, let model = judgeModels[provider.rawValue] { return model }
        guard let model = models[provider.rawValue] else {
            preconditionFailure("Missing test model for \(provider.rawValue)")
        }
        return model
    }
}
#endif
