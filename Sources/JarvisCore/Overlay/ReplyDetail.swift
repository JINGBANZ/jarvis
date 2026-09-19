import Foundation

public struct ReplyDetail: Sendable, Equatable {
    public struct Fence: Sendable, Equatable {
        /// The info string's first word, lowercased; empty when there is none.
        public let language: String
        public let body: String
        /// Opener and closer included.
        let range: Range<String.Index>
        /// False when the document ended before the closer.
        let isClosed: Bool

        var isDiagram: Bool { language == "mermaid" }
    }

    public enum Segment: Sendable, Equatable {
        /// A later fence of an already shown kind stays here as an inline code block.
        case prose(AttributedString)
        case code(CodeBlock)
        case diagram(DiagramHint)
    }

    /// In the order the markdown wrote them; at most one code block and one diagram.
    public let segments: [Segment]
    public let dropped: [String]
    /// What the model replays and Activity records: the detail minus any dropped fence.
    public let deliveredMarkdown: String

    public var hasContent: Bool { !segments.isEmpty }

    public var code: CodeBlock? {
        for case .code(let block) in segments { return block }
        return nil
    }

    public var diagram: DiagramHint? {
        for case .diagram(let diagram) in segments { return diagram }
        return nil
    }

    /// Nil when the markdown is blank.
    public init?(markdown: String) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(parsing: markdown)
    }

    /// Blank markdown parses to a detail with no content.
    init(parsing markdown: String) {
        var shown: [(range: Range<String.Index>, segment: Segment)] = []
        var dropped: [String] = []
        // Rejected fences also leave the replay, so the model reads back only what the user saw.
        var rejected: [Range<String.Index>] = []

        let fences = Self.fences(in: markdown)
        for fence in fences where fence.isDiagram {
            if let parsed = DiagramHint(mermaid: fence.body) {
                shown.append((fence.range, .diagram(parsed)))
                break
            }
            rejected.append(fence.range)
            dropped.append(Self.diagramDropped)
        }
        for fence in fences where !fence.isDiagram {
            if let parsed = CodeBlock(language: fence.language, code: fence.body) {
                shown.append((fence.range, .code(parsed)))
                break
            }
            rejected.append(fence.range)
            dropped.append(Self.codeDropped)
        }

        var segments: [Segment] = []
        var cursor = markdown.startIndex
        func appendProse(upTo end: String.Index) {
            let inside = rejected.filter { $0.lowerBound >= cursor && $0.upperBound <= end }
            let prose = Self.parseProse(Self.removing(inside, from: markdown[cursor..<end]))
            if !prose.characters.isEmpty { segments.append(.prose(prose)) }
        }
        for block in shown.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            appendProse(upTo: block.range.lowerBound)
            segments.append(block.segment)
            cursor = block.range.upperBound
        }
        appendProse(upTo: markdown.endIndex)

        self.segments = segments
        self.dropped = dropped
        self.deliveredMarkdown = Self.removing(rejected, from: markdown[...])
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
                                        range: start..<afterLine, isClosed: true))
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
                                range: start..<markdown.endIndex, isClosed: false))
        }
        return fences
    }

    // MARK: - Rendering

    private static func removing(_ ranges: [Range<String.Index>], from markdown: Substring) -> String {
        guard !ranges.isEmpty else { return String(markdown) }
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
