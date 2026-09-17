import Foundation

public final class BrainPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var provider: BrainProvider {
        get {
            guard let raw = defaults.string(forKey: Defaults.Brain.providerKey),
                  let provider = BrainProvider(rawValue: raw) else { return Defaults.Brain.provider }
            return provider
        }
        set {
            defaults.set(newValue.rawValue, forKey: Defaults.Brain.providerKey)
            fallbackTargets = fallbackTargets
        }
    }

    public var primaryTarget: BrainTarget {
        BrainTarget(provider: provider, modelID: model(for: provider).id)
    }

    public var fallbackTargets: [BrainTarget] {
        get {
            guard let stored = defaults.array(forKey: Defaults.Brain.fallbackTargetsKey) else {
                return Defaults.Brain.fallbackTargets
            }
            let candidates = stored.compactMap { persistedTarget(from: $0) }
            let normalized = BrainRoute(
                primary: primaryTarget, fallbackTargets: candidates).fallbackTargets
            persistFallbackTargets(normalized)
            return normalized
        }
        set {
            persistFallbackTargets(BrainRoute(
                primary: primaryTarget, fallbackTargets: newValue).fallbackTargets)
        }
    }

    /// The runtime cursor and failure counters deliberately live elsewhere.
    public var route: BrainRoute {
        get { BrainRoute(primary: primaryTarget, fallbackTargets: fallbackTargets) }
        set {
            defaults.set(newValue.primary.provider.rawValue, forKey: Defaults.Brain.providerKey)
            defaults.set(
                newValue.primary.modelID,
                forKey: Defaults.Brain.modelKey(for: newValue.primary.provider))
            persistFallbackTargets(newValue.fallbackTargets)
        }
    }

    public var model: BrainModel {
        get { model(for: provider) }
        set { setModel(newValue, for: provider) }
    }

    public func model(for provider: BrainProvider) -> BrainModel {
        guard let id = defaults.string(forKey: Defaults.Brain.modelKey(for: provider)),
              let model = BrainModelCatalog.model(id: id, for: provider) else {
            return Defaults.Brain.model(for: provider)
        }
        return model
    }

    public func setModel(_ model: BrainModel, for provider: BrainProvider) {
        defaults.set(model.id, forKey: Defaults.Brain.modelKey(for: provider))
        if provider == self.provider {
            fallbackTargets = fallbackTargets
        }
    }

    public var effort: ReasoningEffort {
        get {
            guard let raw = defaults.string(forKey: Defaults.Brain.effortKey),
                  let effort = ReasoningEffort(rawValue: raw) else { return Defaults.Brain.effort }
            return effort
        }
        set { defaults.set(newValue.rawValue, forKey: Defaults.Brain.effortKey) }
    }

    /// Stores what is off, so a tool added in a later version starts on. Required tools are dropped
    /// on write.
    public var disabledTools: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Defaults.Brain.disabledToolsKey)
                ?? Defaults.Brain.disabledTools)
        }
        set {
            defaults.set(
                newValue.subtracting(CoachCapabilities.fixedToolNames).sorted(),
                forKey: Defaults.Brain.disabledToolsKey)
        }
    }

    public var disabledSkills: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Defaults.Brain.disabledSkillsKey)
                ?? Defaults.Brain.disabledSkills)
        }
        set { defaults.set(newValue.sorted(), forKey: Defaults.Brain.disabledSkillsKey) }
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
        }, forKey: Defaults.Brain.fallbackTargetsKey)
    }
}
