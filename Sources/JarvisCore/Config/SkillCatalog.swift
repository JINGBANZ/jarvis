import Foundation

/// Lives outside the coach because the coaching kernel may not touch the filesystem
/// (`scripts/check-coaching-kernel.sh`).
public enum SkillCatalog {
    /// Sorted by name. An unreadable or invalid skill file is skipped and logged, never fatal.
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

    /// A frontmatter line that is not `key: value` throws rather than being skipped, so a
    /// description wrapped onto a second line can't ship truncated.
    public static func parse(_ text: String, folderName: String) throws -> Skill {
        // `CharacterSet.whitespaces` excludes \r, so a CRLF file would fail the fence check.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
        let body = lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw SkillParseError.missingBody }
        return Skill(name: name, description: description, body: body)
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

    /// Avoids `Bundle.module`, whose accessor `fatalError`s in an installed app. Probes the
    /// installed app, the executable's directory, then (for `swift test`) the source tree via
    /// `#filePath`. A candidate counts only when it holds a skill, so an empty directory can't
    /// shadow the source.
    private static func skillsDirectory() -> URL? {
        let resourceBundle = "Jarvis_JarvisCore.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(resourceBundle)
                .appendingPathComponent("Skills"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundle)
            .appendingPathComponent("Skills"))
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent("Skills"))
        return candidates.first { !skillFiles(in: $0).isEmpty }
    }

    static func skillFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter {
                guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                else { return false }
                // Nested skills are bundled directories; do not follow links out of the tree or into a cycle.
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .flatMap { folder -> [URL] in
                let own = folder.appendingPathComponent(skillFileName)
                let files = FileManager.default.fileExists(atPath: own.path) ? [own] : []
                return files + skillFiles(in: folder)
            }
            .sorted { $0.path < $1.path }
    }
}

public enum SkillParseError: Error, Equatable, CustomStringConvertible {
    case missingFrontmatter
    case unterminatedFrontmatter
    case malformedFrontmatterLine(String)
    case missingName
    case invalidName(String)
    case nameDoesNotMatchFolder(name: String, folder: String)
    case missingDescription
    case descriptionTooLong(Int)
    case missingBody

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
        case .missingBody: "nothing follows the frontmatter"
        }
    }
}
