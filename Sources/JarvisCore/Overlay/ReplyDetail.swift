import Foundation

/// One `speak.detail` value, split into what the detail box shows. Foundation only, so the routing
/// rules are unit-tested without a window.
///
/// A detail is one Markdown document. Most of it is prose, and at most one fenced block of each
/// routed kind is lifted out of that prose and drawn as its own block: the first `mermaid` fence the
/// diagram renderer accepts, and the first other fence that fits the code bounds. A fence the box
/// cannot show is removed from both the prose and `deliveredMarkdown`, and `dropped` says why, so
/// the model reads back what the user actually saw instead of assuming its block landed.
public struct ReplyDetail: Sendable, Equatable {
    /// One fenced block, as CommonMark delimits it.
    public struct Fence: Sendable, Equatable {
        /// The info string's first word, lowercased. Empty when the fence named none.
        public let language: String
        public let body: String
        /// Where the whole fence sits in the source, opener and closer included.
        let range: Range<String.Index>
    }

    /// Everything but the routed and dropped fences, parsed as Markdown. A second fence of a routed
    /// kind stays here and renders as an inline code block.
    public let prose: AttributedString
    /// The first non-mermaid fence within bounds.
    public let code: CodeBlock?
    /// The first `mermaid` fence the renderer accepts.
    public let diagram: DiagramHint?
    /// Why a fence was not shown, in the words the tool result gives the model.
    public let dropped: [String]
    /// What the model replays and Activity records: the detail as sent, minus any dropped fence.
    public let deliveredMarkdown: String

    /// Whether the box has anything to put on screen. A detail that was nothing but a diagram the
    /// renderer refused leaves the box as it was.
    public var hasContent: Bool {
        code != nil || diagram != nil || !prose.characters.isEmpty
    }

    /// Nil when the detail is blank, which is the same as no detail at all.
    public init?(markdown: String) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var diagram: DiagramHint?
        var code: CodeBlock?
        var dropped: [String] = []
        // Removed from the prose because the box draws them itself; removed from the replay too when
        // the box drew nothing.
        var liftedFromProse: [Range<String.Index>] = []
        var removedFromReplay: [Range<String.Index>] = []

        let fences = Self.fences(in: markdown)
        if let mermaid = fences.first(where: { $0.language == "mermaid" }) {
            liftedFromProse.append(mermaid.range)
            if let parsed = DiagramHint(mermaid: mermaid.body) {
                diagram = parsed
            } else {
                removedFromReplay.append(mermaid.range)
                dropped.append(Self.diagramDropped)
            }
        }
        if let block = fences.first(where: { $0.language != "mermaid" }) {
            liftedFromProse.append(block.range)
            if let parsed = CodeBlock(language: block.language, code: block.body) {
                code = parsed
            } else {
                removedFromReplay.append(block.range)
                dropped.append(Self.codeDropped)
            }
        }

        self.code = code
        self.diagram = diagram
        self.dropped = dropped
        self.deliveredMarkdown = Self.removing(removedFromReplay, from: markdown)
        self.prose = Self.parseProse(Self.removing(liftedFromProse, from: markdown))
    }

    // MARK: - Fence scanning

    /// Splits `markdown` into its fenced blocks, following CommonMark: three or more backticks or
    /// tildes open a fence, a run of the same character at least as long closes it, and an unclosed
    /// fence runs to the end of the document.
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
                // Only a run of the opening character, at least as long, closes the fence. Anything
                // else is body, including a shorter or differently marked run.
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
                // A backtick fence's info string may not contain a backtick (CommonMark), which is
                // what keeps inline code from opening one.
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
        // An unclosed fence runs to the end of the document.
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

    /// Markdown with structure kept as presentation intents, which the box maps to paragraphs and
    /// list bullets. A link or image keeps only its text: the box is capture-excluded and inert, so
    /// a destination it can never open is noise the model could use to point somewhere.
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

    // The reasons the tool result gives the model, so a dropped block is a fact it can act on rather
    // than something it assumes landed.
    static let diagramDropped = "the diagram was not a supported graph and was not shown"
    static let codeDropped =
        "the code block exceeded \(CodeBlock.lineLimit) lines or \(CodeBlock.characterLimit) "
        + "characters and was not shown"
}
