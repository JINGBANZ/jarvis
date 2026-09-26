import AppKit

extension DetailProseFormatting {
    /// The block a run belongs to and the quotes and list items around it.
    struct Block {
        enum Kind: Equatable {
            case paragraph
            case heading(level: Int)
            case code
            case rule
            /// The parser gives raw HTML no block intent; it shows as written.
            case html
        }

        enum Container: Equatable {
            case quote(Int)
            case item(Int, list: Int, marker: String)
        }

        let kind: Kind
        /// Nil for HTML and for text the parser could not structure.
        let identity: Int?
        /// Outermost first.
        let containers: [Container]

        var isQuoted: Bool { containers.contains { if case .quote = $0 { true } else { false } } }

        /// A table's kinds are left to `Table.Cell`. An unknown future kind reads as a paragraph.
        init(_ run: AttributedString.Runs.Run) {
            var kind = Kind.paragraph
            var containers: [Container] = []
            var list: (identity: Int, isOrdered: Bool)?
            for component in run.presentationIntent?.components.reversed() ?? [] {
                switch component.kind {
                case .paragraph: kind = .paragraph
                case .header(let level): kind = .heading(level: level)
                case .codeBlock: kind = .code
                case .thematicBreak: kind = .rule
                case .blockQuote: containers.append(.quote(component.identity))
                case .orderedList: list = (component.identity, true)
                case .unorderedList: list = (component.identity, false)
                case .listItem(let ordinal):
                    let depth = containers.count(where: { if case .item = $0 { true } else { false } })
                    let marker = list?.isOrdered == true
                        ? "\(ordinal)." : Self.bullets[depth % Self.bullets.count]
                    containers.append(.item(component.identity, list: list?.identity ?? component.identity,
                                            marker: marker))
                case .table, .tableHeaderRow, .tableRow, .tableCell: break
                @unknown default: break
                }
            }
            if run.presentationIntent == nil, run.inlinePresentationIntent?.contains(.blockHTML) == true {
                kind = .html
            }
            self.kind = kind
            self.identity = run.presentationIntent?.components.first?.identity
            self.containers = containers
        }

        private static let bullets = ["•", "◦", "▪"]
    }

    /// Paragraph styles for quotes, list items, and rules, measured from one font size.
    @MainActor struct BlockStyles {
        private let markerFont: NSFont
        private let minimumColumn: CGFloat
        private let gap: CGFloat
        /// Each list's marker column, wide enough for its widest marker.
        private var columns: [Int: CGFloat] = [:]
        /// One block per quote, so the bar runs unbroken through the quote's paragraphs.
        private var quotes: [Int: NSTextBlock] = [:]

        init(fontSize: CGFloat) {
            markerFont = .systemFont(ofSize: fontSize)
            minimumColumn = (fontSize * 1.6).rounded()
            gap = (fontSize * 0.5).rounded()
        }

        /// Every block goes through here before any is styled, so a list's `100.` widens the column
        /// its `99.` sits in too.
        mutating func fit(_ block: Block) {
            for case .item(_, let list, let marker) in block.containers {
                let width = (marker as NSString).size(withAttributes: [.font: markerFont]).width
                columns[list] = max(column(list), (width + gap).rounded(.up))
            }
        }

        private func column(_ list: Int) -> CGFloat { columns[list] ?? minimumColumn }

        /// Items of one list sit on consecutive lines; anything else is a blank line apart.
        static func areTight(_ above: [Block.Container], _ below: [Block.Container]) -> Bool {
            let lists = Set(above.compactMap { if case .item(_, let list, _) = $0 { list } else { nil } })
            return below.contains { if case .item(_, let list, _) = $0 { lists.contains(list) } else { false } }
        }

        /// A list item's marker sits in its parent's text column, and a tab carries the text to its own,
        /// so the lines the text wraps onto line up under it.
        mutating func paragraph(_ containers: [Block.Container], marker: Bool = false,
                                rule: Bool = false) -> NSParagraphStyle? {
            var blocks: [NSTextBlock] = []
            var indent: CGFloat = 0
            var markerColumn: CGFloat = 0
            for container in containers {
                switch container {
                case .quote(let identity):
                    blocks.append(quote(identity, margin: indent))
                    indent = 0
                case .item(_, let list, _):
                    markerColumn = column(list)
                    indent += markerColumn
                }
            }
            if rule {
                blocks.append(Self.rule(margin: indent))
                indent = 0
            }
            guard !blocks.isEmpty || indent > 0 else { return nil }
            let style = NSMutableParagraphStyle()
            style.textBlocks = blocks
            style.headIndent = indent
            style.firstLineHeadIndent = marker ? indent - markerColumn : indent
            if marker { style.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
            return style
        }

        private mutating func quote(_ identity: Int, margin: CGFloat) -> NSTextBlock {
            if let block = quotes[identity] { return block }
            let block = Self.fullWidth(margin: margin)
            block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(DetailProseFormatting.divider, for: .minX)
            block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
            quotes[identity] = block
            return block
        }

        private static func rule(margin: CGFloat) -> NSTextBlock {
            let block = fullWidth(margin: margin)
            block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(DetailProseFormatting.divider, for: .maxY)
            return block
        }

        /// A text block with no width shrinks to its content, one character per line in a quote.
        private static func fullWidth(margin: CGFloat) -> NSTextBlock {
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(margin, type: .absoluteValueType, for: .margin, edge: .minX)
            return block
        }
    }
}
