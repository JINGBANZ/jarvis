import Foundation

/// Persisted brain selection: the `BrainProvider`, the `BrainModel` chosen *per provider*, and the
/// `ReasoningEffort` applied to whichever is active. Backed by UserDefaults; each is stored
/// independently, so switching providers keeps every other choice (and each provider remembers its
/// own model). Reads are validated against the catalog/enum — a stored value that no longer exists
/// (e.g. a model dropped from the catalog) falls back to the default rather than reaching the API.
/// Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)` in
/// tests. Mirrors `OverlayAppearance`.
public final class BrainPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let provider = "brain.provider"
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
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
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
}
