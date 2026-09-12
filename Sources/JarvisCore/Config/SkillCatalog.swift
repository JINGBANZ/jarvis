import Foundation

/// The coaching skills this build ships, read once at Start.
///
/// Lives in `Config/` rather than beside the coach: this is the only part of the skill path that
/// touches the filesystem, and the coaching kernel may not (`scripts/check-coaching-kernel.sh`).
/// The kernel is handed the parsed result, like every other control-plane snapshot.
public enum SkillCatalog {
    /// Every valid `<name>/SKILL.md` under the bundled skills directory, sorted by name. An
    /// unreadable or invalid file is skipped rather than fatal — a broken skill costs its own
    /// guidance, never the session — and the count is logged so the cause is visible at Start.
    public static func bundled() -> [Skill] {
        guard let directory = skillsDirectory() else {
            jlog("Jarvis coach skills: none found — coaching without them")
            return []
        }
        let skills = skillFiles(in: directory).compactMap { url -> Skill? in
            let folder = url.deletingLastPathComponent().lastPathComponent
            do {
                return try parse(String(contentsOf: url, encoding: .utf8), folderName: folder)
            } catch {
                jlog("Jarvis coach skills: skipped \(folder) — \(error)")
                return nil
            }
        }.sorted { $0.name < $1.name }
        jlog("Jarvis coach skills: \(skills.count) bundled ("
            + (skills.isEmpty ? "none" : skills.map(\.name).joined(separator: ",")) + ")")
        return skills
    }

    /// Frontmatter, then the body. The file opens with a `---` line; `key: value` lines follow
    /// until the closing `---`; a value may be wrapped in single or double quotes; unknown keys are
    /// ignored. A frontmatter line that is not `key: value` is an error rather than something to
    /// skip: silently dropping it is how a description continued onto a second line would ship
    /// truncated.
    public static func parse(_ text: String, folderName: String) throws -> Skill {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == fence else {
            throw SkillParseError.missingFrontmatter
        }
        guard let closing = lines.dropFirst()
            .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == fence }) else {
            throw SkillParseError.unterminatedFrontmatter
        }
        var fields: [String: String] = [:]
        for line in lines[1..<closing] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let separator = trimmed.firstIndex(of: ":") else {
                throw SkillParseError.malformedFrontmatterLine(trimmed)
            }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            fields[key] = unquoted(value)
        }

        guard let name = fields["name"], !name.isEmpty else { throw SkillParseError.missingName }
        guard name.count <= nameLimit, isKebabCase(name) else {
            throw SkillParseError.invalidName(name)
        }
        guard name == folderName else {
            throw SkillParseError.nameDoesNotMatchFolder(name: name, folder: folderName)
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParseError.missingDescription
        }
        guard description.count <= descriptionLimit else {
            throw SkillParseError.descriptionTooLong(description.count)
        }
        return Skill(
            name: name,
            description: description,
            body: lines[(closing + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let fence = "---"
    private static let nameLimit = 64
    private static let descriptionLimit = 1024
    private static let skillFileName = "SKILL.md"

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
              value.last == quote else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func isKebabCase(_ name: String) -> Bool {
        let segments = name.split(separator: "-", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
        }
    }

    /// The same three layouts `SileroVoiceActivityDetector.bundledModelURL()` probes, for the same
    /// reason: `Bundle.module`'s generated accessor looks only beside `Bundle.main.bundleURL` or at
    /// the absolute build path baked in at compile time, and `fatalError`s when neither exists — a
    /// real install has neither. Under `swift test`, `Bundle.main` is the toolchain's testing
    /// helper, unrelated to this checkout, so the source tree is read through `#filePath`.
    ///
    /// A candidate counts only when it actually holds a skill: an empty `Skills` directory beside
    /// the executable would otherwise shadow the checked-out one under test.
    private static func skillsDirectory() -> URL? {
        let resourceBundle = "Jarvis_JarvisCore.bundle"
        var candidates: [URL] = []
        // Installed app: the packaging scripts copy the resource bundle into Contents/Resources.
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(resourceBundle)
                .appendingPathComponent("Skills"))
        }
        // `swift build`/`swift run`, the benchmark harness: SwiftPM leaves it beside the executable.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundle)
            .appendingPathComponent("Skills"))
        // `swift test`: read the checked-out source directly, two directories up from this file
        // (Config/ -> JarvisCore/) and back down into Resources/Skills/.
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent("Skills"))
        return candidates.first { !skillFiles(in: $0).isEmpty }
    }

    /// `<directory>/<folder>/SKILL.md` for every subdirectory that has one, in name order.
    private static func skillFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .map { $0.appendingPathComponent(skillFileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }
}

/// Why one `SKILL.md` was rejected. Bundled files are validated by a test, so these reach a user
/// only through a corrupted install — but they name the offending file's problem in the debug log.
public enum SkillParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter
    case unterminatedFrontmatter
    case malformedFrontmatterLine(String)
    case missingName
    case invalidName(String)
    case nameDoesNotMatchFolder(name: String, folder: String)
    case missingDescription
    case descriptionTooLong(Int)

    public var description: String {
        switch self {
        case .missingFrontmatter: "the file does not open with a --- frontmatter line"
        case .unterminatedFrontmatter: "the frontmatter has no closing --- line"
        case .malformedFrontmatterLine(let line): "frontmatter line is not key: value — \(line)"
        case .missingName: "frontmatter has no name"
        case .invalidName(let name): "name is not lowercase kebab-case, 64 characters or fewer — \(name)"
        case .nameDoesNotMatchFolder(let name, let folder): "name \(name) is not its folder \(folder)"
        case .missingDescription: "frontmatter has no description"
        case .descriptionTooLong(let count): "description is \(count) characters, over 1024"
        }
    }
}
