import Foundation

/// Persisted brain-model selection: which `BrainModel` to use and the `ReasoningEffort` to apply to
/// it. Backed by UserDefaults; the two are stored independently, so the effort is set once and carries
/// across model changes. Reads are validated against the catalog/enum — a stored value that no longer
/// exists (e.g. a model dropped from the catalog) falls back to the default rather than reaching the
/// API. Foundation-only so it stays unit-testable in JarvisCore; inject a `UserDefaults(suiteName:)`
/// in tests. Mirrors `OverlayAppearance`.
public final class BrainPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let model = "brain.model"
        static let effort = "brain.reasoningEffort"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The selected brain model. Absent or unknown id → catalog default.
    public var model: BrainModel {
        get {
            guard let id = defaults.string(forKey: Key.model),
                  let model = BrainModelCatalog.model(id: id) else { return BrainModelCatalog.default }
            return model
        }
        set { defaults.set(newValue.id, forKey: Key.model) }
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
