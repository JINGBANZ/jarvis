#if JARVIS_LIVE_E2E // Debug builds only: see liveE2ESettings in Package.swift
import Foundation

/// One live e2e scenario: the session settings a launch starts with and the ordered steps it drives.
///
/// Decoded from `Tests/JarvisLiveTests/Scenarios/*.json` through a private string-typed layer, then
/// validated into this model. The Core enums it names stay free of `Codable` conformances, because
/// their raw strings are this file format's concern, not theirs.
public struct LiveE2EScenario: Sendable, Equatable {
    public enum Failure: Error, CustomStringConvertible {
        case invalid(String)

        public var description: String {
            switch self {
            case .invalid(let detail): "Invalid live e2e scenario: \(detail)"
            }
        }
    }

    public enum Audio: String, Sendable {
        case fixture
        case device
        case fixtureNoSystem = "fixture-no-system"
        case fixtureNoMicrophone = "fixture-no-microphone"
    }

    public struct Brain: Sendable, Equatable {
        public let primary: BrainProvider
        public let fallbacks: [BrainProvider]
    }

    public struct Capabilities: Sendable, Equatable {
        public let disabledTools: [String]
        public let disabledSkills: [String]
    }

    public enum TranscriptionKey: String, Sendable {
        case standard
        case invalid
    }

    public struct Transcription: Sendable, Equatable {
        public let model: OpenAITranscriptionModel
        public let key: TranscriptionKey
    }

    public struct Voices: Sendable, Equatable {
        public let them: String
        public let me: String
    }

    public struct Line: Sendable, Equatable {
        public let speaker: Speaker
        public let text: String
    }

    public struct Overlap: Sendable, Equatable {
        public let speaker: Speaker
        public let text: String
        public let afterSeconds: Double
    }

    public enum Step: Sendable, Equatable {
        case screen(fixture: String)
        case press(CoachingShortcut)
        case say(Line, overlap: Overlap?, whileAttemptRunning: Bool)
        case switchBrain(BrainProvider)
        case stop
    }

    public let id: String
    public let audio: Audio
    public let brain: Brain
    public let capabilities: Capabilities
    /// A file name inside the fixtures directory, or nil.
    public let prepNotes: String?
    public let transcription: Transcription
    public let voices: Voices
    public let steps: [Step]

    /// Decode and validate. Throws a descriptive error naming the step index when a rule fails.
    public static func load(from url: URL, fixturesDirectory: URL) throws -> LiveE2EScenario {
        try decode(Data(contentsOf: url), fixturesDirectory: fixturesDirectory)
    }

    public static func decode(_ data: Data, fixturesDirectory: URL) throws -> LiveE2EScenario {
        let raw = try JSONDecoder().decode(RawScenario.self, from: data)
        return try LiveE2EScenario(raw: raw, fixturesDirectory: fixturesDirectory)
    }
}

extension LiveE2EScenario {
    private init(raw: RawScenario, fixturesDirectory: URL) throws {
        // ASCII only: the id names the scenario's output directory and appears in test filters.
        guard !raw.id.isEmpty,
              raw.id.allSatisfy({ $0 == "-" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else {
            throw Failure.invalid("id must be non-empty letters, digits, and -: \"\(raw.id)\"")
        }
        let audio = try Self.parse(Audio.self, raw.audio, "audio")
        let primary = try Self.parse(BrainProvider.self, raw.brain.primary, "brain.primary")
        let fallbacks = try raw.brain.fallbacks.map {
            try Self.parse(BrainProvider.self, $0, "brain.fallbacks")
        }
        if let prepNotes = raw.prepNotes {
            try Self.requireFixture(prepNotes, in: fixturesDirectory, field: "prepNotes")
        }
        let model = try Self.parse(
            OpenAITranscriptionModel.self, raw.transcription.model, "transcription.model")
        let key = try Self.parse(TranscriptionKey.self, raw.transcription.key, "transcription.key")

        id = raw.id
        self.audio = audio
        brain = Brain(primary: primary, fallbacks: fallbacks)
        capabilities = Capabilities(
            disabledTools: raw.capabilities.disabledTools,
            disabledSkills: raw.capabilities.disabledSkills)
        prepNotes = raw.prepNotes
        transcription = Transcription(model: model, key: key)
        voices = Voices(them: raw.voices.them, me: raw.voices.me)
        steps = try Self.steps(from: raw.steps, primary: primary, fixturesDirectory: fixturesDirectory)

        // A stream the audio setting does not play carries no synthesized speech, so a line on it
        // would leave the runner waiting out an attempt that never starts.
        func plays(_ speaker: Speaker) -> Bool {
            switch audio {
            case .fixture: true
            case .fixtureNoSystem: speaker == .me
            case .fixtureNoMicrophone: speaker == .them
            case .device: false
            }
        }
        for (index, step) in steps.enumerated() {
            guard case .say(let line, let overlap, _) = step else { continue }
            for speaker in [line.speaker] + [overlap?.speaker].compactMap({ $0 }) where !plays(speaker) {
                throw Failure.invalid(
                    "steps[\(index)]: \"\(audio.rawValue)\" audio cannot speak as \(speaker.rawValue)")
            }
        }
    }

    private static func steps(
        from rawSteps: [RawStep],
        primary: BrainProvider,
        fixturesDirectory: URL
    ) throws -> [Step] {
        guard !rawSteps.isEmpty else {
            throw Failure.invalid("steps must not be empty")
        }
        var currentBrain = primary
        var steps: [Step] = []
        for (index, raw) in rawSteps.enumerated() {
            let label = "steps[\(index)]"
            func invalid(_ detail: String) -> Failure { .invalid("\(label): \(detail)") }

            if let unknown = raw.unknownKeys.first {
                throw invalid("unknown key \"\(unknown)\"")
            }
            let primaryKeys = raw.primaryKeys
            guard primaryKeys.count == 1, let key = primaryKeys.first else {
                throw invalid(
                    "needs exactly one of \(RawStep.primaryKeyNames.joined(separator: ", ")), "
                        + "found \(primaryKeys.count)")
            }
            if key != "say", raw.overlap != nil || raw.whileAttemptRunning != nil {
                throw invalid("overlap and whileAttemptRunning apply only to a say step")
            }

            let step: Step
            switch key {
            case "screen":
                let fixture = raw.screen ?? ""
                try requireFixture(fixture, in: fixturesDirectory, field: "\(label).screen")
                // The image goes to the coach as the captured screen, so it must be what a capture makes.
                guard ["jpg", "jpeg"].contains(URL(fileURLWithPath: fixture).pathExtension.lowercased()) else {
                    throw Failure.invalid("\(label).screen must be a JPEG image, got \"\(fixture)\"")
                }
                step = .screen(fixture: fixture)
            case "press":
                step = .press(try shortcut(raw.press ?? "", label: label))
            case "say":
                guard let line = raw.say else {
                    throw invalid("say must be an object with speaker and text")
                }
                let whileAttemptRunning = raw.whileAttemptRunning ?? false
                // The first step has no earlier attempt to overlap.
                if index == 0, whileAttemptRunning {
                    throw invalid("whileAttemptRunning cannot mark the first step")
                }
                var overlap: Overlap?
                if let rawOverlap = raw.overlap {
                    guard rawOverlap.afterSeconds > 0 else {
                        throw invalid("overlap.afterSeconds must be positive")
                    }
                    overlap = Overlap(
                        speaker: try parse(Speaker.self, rawOverlap.speaker, "\(label).overlap.speaker"),
                        text: rawOverlap.text,
                        afterSeconds: rawOverlap.afterSeconds)
                }
                step = .say(
                    Line(speaker: try parse(Speaker.self, line.speaker, "\(label).say.speaker"),
                         text: line.text),
                    overlap: overlap,
                    whileAttemptRunning: whileAttemptRunning)
            case "switchBrain":
                let provider = try parse(BrainProvider.self, raw.switchBrain ?? "", "\(label).switchBrain")
                guard provider != currentBrain else {
                    throw invalid("switchBrain names the current brain \"\(provider.rawValue)\"")
                }
                currentBrain = provider
                step = .switchBrain(provider)
            default:
                guard raw.stop == true else {
                    throw invalid("stop must be true")
                }
                guard index == rawSteps.count - 1 else {
                    throw invalid("stop must be the last step")
                }
                step = .stop
            }
            steps.append(step)
        }
        guard steps.last == .stop else {
            throw Failure.invalid("steps[\(steps.count - 1)]: the last step must be stop")
        }
        return steps
    }

    private static func shortcut(_ raw: String, label: String) throws -> CoachingShortcut {
        switch raw {
        case "hint": .hint
        case "explainMore": .explainMore
        case "showCode": .showCode
        default: throw Failure.invalid("\(label).press: unknown shortcut \"\(raw)\"")
        }
    }

    private static func parse<Value: RawRepresentable>(
        _ type: Value.Type,
        _ raw: String,
        _ field: String
    ) throws -> Value where Value.RawValue == String {
        guard let value = Value(rawValue: raw) else {
            throw Failure.invalid("\(field): unknown value \"\(raw)\"")
        }
        return value
    }

    /// A fixture reference must be a plain file name so a scenario cannot reach outside the
    /// fixtures directory the launcher copies.
    private static func requireFixture(_ name: String, in directory: URL, field: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else {
            throw Failure.invalid("\(field) must be a plain file name, got \"\(name)\"")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(name).path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw Failure.invalid("\(field) names no file in the fixtures directory: \"\(name)\"")
        }
    }
}

// MARK: - Raw JSON layer

private struct RawScenario: Decodable {
    struct Brain: Decodable {
        let primary: String
        let fallbacks: [String]
    }

    struct Capabilities: Decodable {
        let disabledTools: [String]
        let disabledSkills: [String]
    }

    struct Transcription: Decodable {
        let model: String
        let key: String
    }

    struct Voices: Decodable {
        let them: String
        let me: String
    }

    let id: String
    let audio: String
    let brain: Brain
    let capabilities: Capabilities
    let prepNotes: String?
    let transcription: Transcription
    let voices: Voices
    let steps: [RawStep]
}

private struct RawLine: Decodable {
    let speaker: String
    let text: String
}

private struct RawOverlap: Decodable {
    let speaker: String
    let text: String
    let afterSeconds: Double
}

/// A step object as written: every recognized key decoded if present, and every other key kept by
/// name so validation can reject it with the step's index.
private struct RawStep: Decodable {
    static let primaryKeyNames = ["screen", "press", "say", "switchBrain", "stop"]
    static let modifierKeyNames = ["overlap", "whileAttemptRunning"]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    let primaryKeys: [String]
    let unknownKeys: [String]
    let screen: String?
    let press: String?
    let say: RawLine?
    let switchBrain: String?
    let stop: Bool?
    let overlap: RawOverlap?
    let whileAttemptRunning: Bool?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let names = container.allKeys.map(\.stringValue)
        primaryKeys = names.filter { Self.primaryKeyNames.contains($0) }
        unknownKeys = names.filter {
            !Self.primaryKeyNames.contains($0) && !Self.modifierKeyNames.contains($0)
        }
        screen = try container.decodeIfPresent(String.self, forKey: Key("screen"))
        press = try container.decodeIfPresent(String.self, forKey: Key("press"))
        say = try container.decodeIfPresent(RawLine.self, forKey: Key("say"))
        switchBrain = try container.decodeIfPresent(String.self, forKey: Key("switchBrain"))
        stop = try container.decodeIfPresent(Bool.self, forKey: Key("stop"))
        overlap = try container.decodeIfPresent(RawOverlap.self, forKey: Key("overlap"))
        whileAttemptRunning = try container.decodeIfPresent(Bool.self, forKey: Key("whileAttemptRunning"))
    }
}
#endif
