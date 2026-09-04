import Foundation

/// The interview format a coaching session is specialized for. Chosen once at Start — like
/// `TranscriptionPreferences.openAIExpectedLanguages` — and fixed for the whole session, never
/// guessed or reclassified mid-conversation: an automatic, in-session classifier was considered and
/// rejected, both for guessing once and locking in (misclassifies a session that shifts formats) and
/// for continuously re-guessing (the same "brittle state machine" a history-compaction design
/// already rejected — see wiki/architecture.md § Models and APIs). No selection means no addendum at
/// all — not a guess assembled from whatever formats happen to have content — so a user who never
/// opens this setting sees no behavior change at all.
public enum InterviewFormat: String, CaseIterable, Codable, Sendable {
    case coding = "coding"
    case systemDesign = "system-design"
    case behavioral = "behavioral"

    public var displayName: String {
        switch self {
        case .coding: "Coding"
        case .systemDesign: "System Design"
        case .behavioral: "Behavioral"
        }
    }

    /// Loaded from `Resources/Skills/<rawValue>.md` — a real Markdown file, not a Swift string
    /// literal, so a skill's content reads and edits like prose. Coding and system design have
    /// authored guidance; behavioral remains empty. Missing file → empty, not a crash — an
    /// unwritten skill is a normal state, not an error.
    public var promptAddendum: String {
        guard let url = Self.skillMarkdownURL(named: rawValue),
              let body = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return ""
        }
        return "\n\n" + body
    }

    /// Locate a skill's Markdown file without `Bundle.module`: its generated accessor looks only
    /// beside `Bundle.main.bundleURL` (the `.app` root, not `Contents/Resources`, where the
    /// packaging scripts actually copy it) or at the absolute build path baked in at compile time,
    /// and **`fatalError`s** when neither exists — a real install has neither, so the crash would
    /// only surface the first time a user picked a format with content. This is the identical
    /// problem `SileroVoiceActivityDetector.bundledModelURL()` already solved for the Silero model;
    /// mirror it rather than trust the generated accessor a second time.
    ///
    /// Three real layouts, none of them optional: `swift test`'s `Bundle.main` is the
    /// `swiftpm-testing-helper` process living inside the toolchain, unrelated to this checkout, so
    /// neither `Bundle.main` candidate below ever resolves under test — read the source file
    /// directly via `#filePath`, the same repo-relative-regardless-of-build-config technique
    /// `Package.swift` already uses for the AEC archive. Return nil only if none of the three has it.
    private static func skillMarkdownURL(named name: String) -> URL? {
        let resourceBundle = "Jarvis_JarvisCore.bundle"
        let file = "Skills/\(name).md"
        var candidates: [URL] = []
        // Installed app: the packaging scripts copy the resource bundle into Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(resourceBundle)
                .appendingPathComponent(file))
        }
        // `swift build`/`swift run`, the benchmark harness: SwiftPM leaves it beside the executable.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundle)
            .appendingPathComponent(file))
        // `swift test`: read the checked-out source directly, two directories up from this file
        // (Config/ -> JarvisCore/) and back down into Resources/Skills/.
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(file))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
