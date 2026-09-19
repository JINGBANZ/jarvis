import Foundation

extension ReplyDetail {
    /// A detail still being written. Text and code show as they arrive, a half-written line
    /// included; a diagram is parsed whole, so an open diagram fence contributes nothing until its
    /// closer arrives. Nil only when the markdown is blank: text that is just an open diagram
    /// fence is a detail with no content yet.
    public init?(partialMarkdown markdown: String) {
        guard let open = Self.openDiagramFence(in: markdown) else {
            self.init(markdown: markdown)
            return
        }
        self.init(parsing: String(markdown[..<open.range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True while the text ends inside a diagram fence, where the box shows a placeholder.
    public static func endsInsideADiagram(_ markdown: String) -> Bool {
        openDiagramFence(in: markdown) != nil
    }

    private static func openDiagramFence(in markdown: String) -> Fence? {
        guard let last = fences(in: markdown).last, last.isDiagram, !last.isClosed else { return nil }
        return last
    }
}
