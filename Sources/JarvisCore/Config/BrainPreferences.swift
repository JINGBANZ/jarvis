import Foundation

/// Persisted brain selection: a primary provider/model target, an ordered list of fallback targets,
/// the `BrainModel` remembered *per provider*, and the `ReasoningEffort` applied to whichever target
/// is active. Backed by UserDefaults; each provider keeps its remembered model independently.
/// Every key and default comes from `Defaults.Brain`; reads normalize stale providers/models and
/// exact route duplicates before they reach the runtime.
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `OverlayAppearance`.
public final class BrainPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The selected brain provider. Absent or unrecognized → `Defaults.Brain.provider`.
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

    /// The selected provider and its remembered model.
    public var primaryTarget: BrainTarget {
        BrainTarget(provider: provider, modelID: model(for: provider).id)
    }

    /// Ordered, explicitly authorized fallback provider/model targets.
    ///
    /// Unknown providers/models, exact primary duplicates, and repeated fallback targets are
    /// removed; order and same-provider/different-model targets are preserved.
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

    /// Complete persisted route. Runtime cursor and failure counters deliberately live elsewhere.
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

    /// The selected model for the *current* provider. Absent or unknown id → that provider's default.
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

    /// The reasoning effort, applied to whichever model is selected. Absent or unrecognized → default.
    public var effort: ReasoningEffort {
        get {
            guard let raw = defaults.string(forKey: Defaults.Brain.effortKey),
                  let effort = ReasoningEffort(rawValue: raw) else { return Defaults.Brain.effort }
            return effort
        }
        set { defaults.set(newValue.rawValue, forKey: Defaults.Brain.effortKey) }
    }

    /// The interview format the coaching prompt is specialized for this session. `nil` means "not
    /// selected" — a real, persisted state, not a fallback to a default — resolved to every format's
    /// combined guidance rather than a guess (`InterviewFormat.resolvedPromptAddendum(for:)`).
    public var interviewFormat: InterviewFormat? {
        get {
            guard let raw = defaults.string(forKey: Defaults.Brain.interviewFormatKey) else {
                return nil
            }
            return InterviewFormat(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: Defaults.Brain.interviewFormatKey) }
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
