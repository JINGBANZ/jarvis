#if JARVIS_LIVE_E2E
import Foundation

public struct EvaluationSuiteCatalog: Codable, Sendable {
    public let suites: [Entry]
    public struct Entry: Codable, Sendable {
        public enum Executor: String, Codable, Sendable { case coachingReplay, signedApp }
        public let id: String
        public let executor: Executor
        public let catalog: String?
        public let scenario: String?
        public let acceptance: String
    }
    public static func load(from url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !value.suites.isEmpty, Set(value.suites.map(\.id)).count == value.suites.count else {
            throw CoachingReplayCatalog.Failure.invalidCatalog
        }
        for entry in value.suites {
            guard !entry.id.isEmpty else { throw CoachingReplayCatalog.Failure.invalidCatalog }
            switch entry.executor {
            case .coachingReplay:
                guard let catalog = entry.catalog, catalog.hasSuffix(".json"),
                      !catalog.contains("/"), !catalog.contains("\\"), entry.scenario == nil,
                      entry.acceptance == "intervention-v1" else { throw CoachingReplayCatalog.Failure.invalidCatalog }
            case .signedApp:
                guard entry.catalog == nil, entry.scenario == "A", entry.acceptance == "signed-app-A-v1" else {
                    throw CoachingReplayCatalog.Failure.invalidCatalog
                }
            }
        }
        return value
    }
}

#endif
