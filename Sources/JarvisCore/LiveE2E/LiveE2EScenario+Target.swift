#if JARVIS_LIVE_E2E
import Foundation

extension LiveE2EScenario {
    public static func target(for provider: BrainProvider, modelID: String? = nil) -> BrainTarget {
        let defaultModel = switch provider {
        case .claudeSubscription: "claude-sonnet-5-5"
        case .openAI, .codexSubscription: "gpt-6-luna"
        case .gemini: BrainModelCatalog.defaultModel(for: .gemini).id
        }
        return BrainTarget(provider: provider, modelID: modelID ?? defaultModel)
    }
}
#endif
