import Foundation

/// Slots are 232 points wide, so these lines stay short.
public enum RobotPartSummaries {
    public static func brain(primary: BrainTarget, effort: ReasoningEffort) -> RobotPartSummary {
        RobotPartSummary(
            value: primary.model?.displayName ?? primary.modelID,
            detail: "VIA \(primary.provider.displayName.uppercased())",
            level: ReasoningEffort.allCases.firstIndex(of: effort) ?? 0)
    }

    public static func ear(_ configuration: TranscriptionConfiguration) -> RobotPartSummary {
        let provider = configuration.provider.displayName
        switch configuration.provider {
        case .openAI:
            return RobotPartSummary(
                value: slotName(provider: provider, model: configuration.openAIModel.displayName),
                detail: hears(configuration.openAIExpectedLanguages))
        case .gemini:
            return RobotPartSummary(
                value: slotName(provider: provider, model: configuration.geminiModel.displayName),
                detail: hears(configuration.geminiExpectedLanguages))
        case .appleSpeech:
            let locale = configuration.appleSpeechLocaleIdentifier
                .replacingOccurrences(of: "_", with: "-").uppercased()
            return RobotPartSummary(value: provider, detail: "HEARS \(locale)")
        }
    }

    public static func eye(
        scope: ScreenCaptureScope, displayIndex: Int, browserTextEnabled: Bool
    ) -> RobotPartSummary {
        switch scope {
        case .activeWindow:
            RobotPartSummary(
                value: "Active window",
                detail: browserTextEnabled ? "CHROME TEXT ON" : "CHROME TEXT OFF")
        case .entireDisplay:
            RobotPartSummary(value: "Display \(displayIndex)", detail: "WHOLE SCREEN")
        }
    }

    public static func mouth(captionEnabled: Bool, boxEnabled: Bool) -> RobotPartSummary {
        let value = switch (boxEnabled, captionEnabled) {
        case (true, true): "Box and caption"
        case (true, false): "Overlay Box"
        case (false, true): "Caption"
        case (false, false): "Nothing on screen"
        }
        return RobotPartSummary(
            value: value,
            detail: "BOX \(boxEnabled ? "ON" : "OFF") · CAPTION \(captionEnabled ? "ON" : "OFF")")
    }

    /// "GPT-4o Transcribe" reads "OpenAI · GPT-4o"; a model already named for its vendor reads
    /// alone ("Gemini 3.5 Live").
    private static func slotName(provider: String, model: String) -> String {
        let short = model.replacingOccurrences(of: " Transcribe", with: "")
        return short.hasPrefix(provider) ? short : "\(provider) · \(short)"
    }

    private static func hears(_ languages: [TranscriptionLanguage]) -> String {
        guard !languages.isEmpty else { return "HEARS ANY LANGUAGE" }
        return "HEARS " + languages.map(code).joined(separator: " · ")
    }

    private static func code(_ language: TranscriptionLanguage) -> String {
        switch language {
        case .english: "EN"
        case .mandarinChinese: "中文"
        }
    }
}
