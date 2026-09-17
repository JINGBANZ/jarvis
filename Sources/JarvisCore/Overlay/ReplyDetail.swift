import Foundation

public struct ReplyDetail: Sendable, Equatable {
    public struct Fence: Sendable, Equatable {
        /// The info string's first word, lowercased; empty when there is none.
        public let language: String
        public let body: String
        /// Opener and closer included.
        let range: Range<String.Index>
    }

    /// A later fence of an already shown kind stays here as an inline code block.
    public let prose: AttributedString
    public let code: CodeBlock?
    public let diagram: DiagramHint?
    public let dropped: [String]
    /// What the model replays and Activity records: the detail minus any dropped fence.
    public let deliveredMarkdown: String

    public var hasContent: Bool {
        code != nil || diagram != nil || !prose.characters.isEmpty
    }

    /// Nil when the markdown is blank.
    public init?(markdown: String) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var diagram: DiagramHint?
        var code: CodeBlock?
        var dropped: [String] = []
        // Rejected fences also leave the replay, so the model reads back only what the user saw.
        var liftedFromProse: [Range<String.Index>] = []
        var removedFromReplay: [Range<String.Index>] = []

        let fences = Self.fences(in: markdown)
        for fence in fences where fence.language == "mermaid" {
            liftedFromProse.append(fence.range)
            if let parsed = DiagramHint(mermaid: fence.body) {
                diagram = parsed
                break
            }
            removedFromReplay.append(fence.range)
            dropped.append(Self.diagramDropped)
        }
        for fence in fences where fence.language != "mermaid" {
            liftedFromProse.append(fence.range)
            if let parsed = CodeBlock(language: fence.language, code: fence.body) {
                code = parsed
                break
            }
            removedFromReplay.append(fence.range)
            dropped.append(Self.codeDropped)
        }

        self.code = code
        self.diagram = diagram
        self.dropped = dropped
        self.deliveredMarkdown = Self.removing(removedFromReplay, from: markdown)
        self.prose = Self.parseProse(Self.removing(liftedFromProse, from: markdown))
    }

    // MARK: - Fence scanning

    /// CommonMark fences; an unclosed fence runs to the end of the document.
    public static func fences(in markdown: String) -> [Fence] {
        var fences: [Fence] = []
        var index = markdown.startIndex
        var openedAt: String.Index?
        var language = ""
        var marker: Character = "`"
        var markerCount = 0
        var bodyStart = markdown.startIndex
        var bodyEnd = markdown.startIndex

        while index < markdown.endIndex {
            let lineEnd = markdown[index...].firstIndex(where: \.isNewline) ?? markdown.endIndex
            let line = markdown[index..<lineEnd]
            let afterLine = lineEnd < markdown.endIndex
                ? markdown.index(after: lineEnd) : markdown.endIndex
            let trimmed = line.drop { $0 == " " }
            let indent = line.count - trimmed.count

            if let start = openedAt {
                let run = trimmed.prefix { $0 == marker }
                if indent <= 3, run.count >= markerCount,
                   trimmed.dropFirst(run.count).allSatisfy({ $0 == " " }) {
                    fences.append(Fence(language: language,
                                        body: String(markdown[bodyStart..<bodyEnd]),
                                        range: start..<afterLine))
                    openedAt = nil
                }
            } else if indent <= 3, let first = trimmed.first, first == "`" || first == "~" {
                let run = trimmed.prefix { $0 == first }
                let info = trimmed.dropFirst(run.count)
                // CommonMark: a backtick in the info string means inline code, not a fence.
                if run.count >= 3, !(first == "`" && info.contains("`")) {
                    openedAt = index
                    marker = first
                    markerCount = run.count
                    language = info.split(whereSeparator: \.isWhitespace).first
                        .map { $0.lowercased() } ?? ""
                    bodyStart = afterLine
                    bodyEnd = afterLine
                }
            }
            if openedAt != nil, index != openedAt { bodyEnd = lineEnd }
            index = afterLine
        }
        if let start = openedAt {
            fences.append(Fence(language: language,
                                body: String(markdown[bodyStart..<bodyEnd]),
                                range: start..<markdown.endIndex))
        }
        return fences
    }

    // MARK: - Rendering

    private static func removing(_ ranges: [Range<String.Index>], from markdown: String) -> String {
        guard !ranges.isEmpty else { return markdown }
        var remaining = ""
        var cursor = markdown.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            remaining += markdown[cursor..<range.lowerBound]
            cursor = range.upperBound
        }
        remaining += markdown[cursor...]
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Links and images keep only their text: the inert box can never open a destination.
    private static func parseProse(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString() }
        var parsed = (try? AttributedString(
            markdown: text,
            options: .init(allowsExtendedAttributes: true,
                           interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
        for run in parsed.runs {
            parsed[run.range].link = nil
            parsed[run.range].imageURL = nil
        }
        return parsed
    }

    static let diagramDropped = "the diagram was not a supported graph and was not shown"
    static let codeDropped =
        "the code block exceeded \(CodeBlock.lineLimit) lines or \(CodeBlock.characterLimit) "
        + "characters and was not shown"
}
