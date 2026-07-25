import Foundation

/// Persisted brain selection: a primary provider/model target, an ordered list of fallback targets,
/// the `BrainModel` remembered *per provider*, and the `ReasoningEffort` applied to whichever target
/// is active. Backed by UserDefaults; each provider keeps its remembered model independently.
/// Reads normalize stale providers/models and exact route duplicates before they reach the runtime.
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `OverlayAppearance`.
public final class BrainPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let provider = "brain.provider"
        static let fallbackTargets = "brain.fallbackTargets"
        /// Read once to migrate installs from the superseded scalar fallback preference.
        static let fallbackProvider = "brain.fallbackProvider"
        static let effort = "brain.reasoningEffort"
        /// The OpenAI model keeps the pre-provider key ("brain.model") so existing installs keep
        /// their selection; CLI providers store under a suffixed key each.
        static func model(for provider: BrainProvider) -> String {
            provider == .openAI ? "brain.model" : "brain.model.\(provider.rawValue)"
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The selected brain provider. Absent or unrecognized → the direct OpenAI API.
    public var provider: BrainProvider {
        get {
            guard let raw = defaults.string(forKey: Key.provider),
                  let provider = BrainProvider(rawValue: raw) else { return .openAI }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
            fallbackTargets = fallbackTargets
        }
    }

    /// The selected provider and its remembered model.
    public var primaryTarget: BrainTarget {
        BrainTarget(provider: provider, modelID: model(for: provider).id)
    }

    /// Ordered, explicitly authorized fallback provider/model targets.
    ///
    /// Reads also migrate the legacy scalar provider key. Unknown providers/models, exact primary
    /// duplicates, and repeated fallback targets are removed; order and same-provider/different-model
    /// targets are preserved.
    public var fallbackTargets: [BrainTarget] {
        get {
            if defaults.object(forKey: Key.fallbackTargets) == nil {
                return migrateLegacyFallback()
            }

            let candidates = (defaults.array(forKey: Key.fallbackTargets) ?? []).compactMap {
                persistedTarget(from: $0)
            }
            let normalized = BrainRoute(
                primary: primaryTarget, fallbackTargets: candidates).fallbackTargets
            persistFallbackTargets(normalized)
            defaults.removeObject(forKey: Key.fallbackProvider)
            return normalized
        }
        set {
            let normalized = BrainRoute(
                primary: primaryTarget, fallbackTargets: newValue).fallbackTargets
            persistFallbackTargets(normalized)
            defaults.removeObject(forKey: Key.fallbackProvider)
        }
    }

    /// Complete persisted route. Runtime cursor and failure counters deliberately live elsewhere.
    public var route: BrainRoute {
        get { BrainRoute(primary: primaryTarget, fallbackTargets: fallbackTargets) }
        set {
            defaults.set(newValue.primary.provider.rawValue, forKey: Key.provider)
            defaults.set(
                newValue.primary.modelID,
                forKey: Key.model(for: newValue.primary.provider))
            persistFallbackTargets(newValue.fallbackTargets)
            defaults.removeObject(forKey: Key.fallbackProvider)
        }
    }

    /// The selected model for the *current* provider. Absent or unknown id → that provider's default.
    public var model: BrainModel {
        get { model(for: provider) }
        set { setModel(newValue, for: provider) }
    }

    public func model(for provider: BrainProvider) -> BrainModel {
        guard let id = defaults.string(forKey: Key.model(for: provider)),
              let model = BrainModelCatalog.model(id: id, for: provider) else {
            return BrainModelCatalog.defaultModel(for: provider)
        }
        return model
    }

    public func setModel(_ model: BrainModel, for provider: BrainProvider) {
        defaults.set(model.id, forKey: Key.model(for: provider))
        if provider == self.provider {
            fallbackTargets = fallbackTargets
        }
    }

    /// The reasoning effort, applied to whichever model is selected. Absent or unrecognized → default.
    public var effort: ReasoningEffort {
        get {
            guard let raw = defaults.string(forKey: Key.effort),
                  let effort = ReasoningEffort(rawValue: raw) else { return .default }
            return effort
        }
        set { defaults.set(newValue.rawValue, forKey: Key.effort) }
    }

    private func migrateLegacyFallback() -> [BrainTarget] {
        let candidates: [BrainTarget]
        if let raw = defaults.string(forKey: Key.fallbackProvider),
           let legacyProvider = BrainProvider(rawValue: raw) {
            candidates = [
                BrainTarget(
                    provider: legacyProvider,
                    modelID: model(for: legacyProvider).id)
            ]
        } else {
            candidates = []
        }

        let normalized = BrainRoute(
            primary: primaryTarget, fallbackTargets: candidates).fallbackTargets
        persistFallbackTargets(normalized)
        defaults.removeObject(forKey: Key.fallbackProvider)
        return normalized
    }

    private func persistedTarget(from value: Any) -> BrainTarget? {
        guard let dictionary = value as? [String: Any],
              let providerRaw = dictionary["provider"] as? String,
              let provider = BrainProvider(rawValue: providerRaw),
              let modelID = dictionary["modelID"] as? String else {
            return nil
        }
        return BrainTarget(provider: provider, modelID: modelID)
    }

    private func persistFallbackTargets(_ targets: [BrainTarget]) {
        defaults.set(targets.map {
            ["provider": $0.provider.rawValue, "modelID": $0.modelID]
        }, forKey: Key.fallbackTargets)
    }
}
