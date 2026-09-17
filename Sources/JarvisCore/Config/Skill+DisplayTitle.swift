import Foundation

extension Skill {
    /// Words kept upper case in a title. Skill names are lowercase kebab-case, so an initialism would
    /// otherwise read as a word ("Coding with ai").
    private static let initialisms: Set<String> = ["ai"]

    /// The skill's name as a sentence-case title: "system-design" reads "System design".
    public var displayTitle: String {
        name.split(separator: "-").enumerated().map { index, word in
            let lower = word.lowercased()
            if Self.initialisms.contains(lower) { return lower.uppercased() }
            return index == 0 ? lower.prefix(1).uppercased() + lower.dropFirst() : lower
        }
        .joined(separator: " ")
    }
}
