import Foundation

extension ReplyDetail {
    /// A detail still being written. An open fence is read up to its last complete line: a diagram
    /// is parsed whole, so a half-written line would drop it on every character until the line ends.
    public init?(partialMarkdown markdown: String) {
        guard let open = Self.fences(in: markdown).last, !open.isClosed,
              markdown.last?.isNewline == false else {
            self.init(markdown: markdown)
            return
        }
        let lastBreak = markdown.lastIndex(where: \.isNewline) ?? open.range.lowerBound
        self.init(markdown: String(markdown[..<lastBreak]))
    }
}
