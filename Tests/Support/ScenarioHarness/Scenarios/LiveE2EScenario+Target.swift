#if JARVIS_LIVE_E2E
import JarvisCore
import Foundation

extension LiveE2EScenario {
    public static func target(for provider: BrainProvider, modelID: String? = nil) -> BrainTarget {
        let defaultModel = TestProviderConfiguration.shared.modelID(for: provider)
        return BrainTarget(provider: provider, modelID: modelID ?? defaultModel)
    }
}
#endif
