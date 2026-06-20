import Foundation

/// One selectable brain (LLM) model: its API id and the label shown in Settings.
public struct BrainModel: Sendable, Equatable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The curated set of OpenAI brain models the user can pick from, confirmed against OpenAI's official
/// model docs (June 2026). The single source of truth for the model dropdown and the default model.
/// Bump this list when OpenAI ships a new model — a one-line edit. (Transcription models are a
/// separate concern and are NOT listed here.)
public enum BrainModelCatalog {
    public static let all: [BrainModel] = [
        BrainModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        BrainModel(id: "gpt-5.4", displayName: "GPT-5.4"),
        BrainModel(id: "gpt-5.4-mini", displayName: "GPT-5.4 mini"),
        BrainModel(id: "gpt-5.4-nano", displayName: "GPT-5.4 nano"),
    ]

    /// The model used when nothing is persisted yet — OpenAI's frontier model.
    public static let `default` = all[0]

    public static func model(id: String) -> BrainModel? {
        all.first { $0.id == id }
    }
}
