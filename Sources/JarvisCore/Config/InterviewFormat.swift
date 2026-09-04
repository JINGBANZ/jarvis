import Foundation

/// An optional interview-format override. The absence of an override supplies automatic routing
/// guidance; the model chooses from current evidence on each coaching attempt without a separate
/// classifier call or persisted in-session format state.
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
        Self.addendum(named: rawValue)
    }

    /// Resolve the Start-time prompt once. A nil override uses one purpose-built automatic skill;
    /// explicit formats remain isolated from it and from one another.
    public static func resolvedPromptAddendum(for override: InterviewFormat?) -> String {
        guard let override else {
            return addendum(named: "automatic")
        }
        return override.promptAddendum
    }

    private static func addendum(named name: String) -> String {
        guard let url = skillMarkdownURL(named: name),
              let body = try? String(contentsOf: url, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return "" }
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
