import AppKit

extension DetailProseFormatting {
    /// One Markdown table: every cell becomes a paragraph whose style carries an `NSTextTableBlock`
    /// of the shared `NSTextTable`, which is how TextKit 1 lays text out as a grid.
    struct Table {
        struct Cell {
            let table: Int
            let columns: [PresentationIntent.TableColumn]
            let row: Int
            let isHeader: Bool
            let column: Int

            /// The parser drops cells past the header's column count, so `column` is always in range.
            init?(_ intent: PresentationIntent) {
                var table: (identity: Int, columns: [PresentationIntent.TableColumn])?
                var row: (identity: Int, isHeader: Bool)?
                var column: Int?
                for component in intent.components {
                    switch component.kind {
                    case .table(let columns): table = (component.identity, columns)
                    case .tableHeaderRow: row = (component.identity, true)
                    case .tableRow: row = (component.identity, false)
                    case .tableCell(let index): column = index
                    default: break
                    }
                }
                guard let table, let row, let column else { return nil }
                self.table = table.identity
                self.columns = table.columns
                self.row = row.identity
                self.isHeader = row.isHeader
                self.column = column
            }
        }

        let identity: Int
        private let columns: [PresentationIntent.TableColumn]
        /// An empty or missing cell still needs its block, or the grid has a hole.
        private var rows: [(identity: Int, isHeader: Bool, cells: [NSMutableAttributedString])] = []

        init(_ cell: Cell) {
            identity = cell.table
            columns = cell.columns
        }

        mutating func append(_ text: NSAttributedString, to cell: Cell) {
            if rows.last?.identity != cell.row {
                rows.append((cell.row, cell.isHeader, columns.map { _ in NSMutableAttributedString() }))
            }
            rows[rows.count - 1].cells[cell.column].append(text)
        }

        /// The last cell leaves its paragraph open for the caller's block separator to close, so a
        /// table that ends the prose adds no empty line below itself.
        func render(body: [NSAttributedString.Key: Any]) -> NSAttributedString {
            let table = NSTextTable()
            table.numberOfColumns = columns.count
            table.collapsesBorders = true
            let out = NSMutableAttributedString()
            for (rowIndex, row) in rows.enumerated() {
                for (columnIndex, cell) in row.cells.enumerated() {
                    let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                 startingColumn: columnIndex, columnSpan: 1)
                    block.setBorderColor(Self.border)
                    block.setWidth(1, type: .absoluteValueType, for: .border)
                    block.setWidth(Self.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
                    block.setWidth(Self.horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
                    block.setWidth(Self.verticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
                    block.setWidth(Self.verticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
                    if row.isHeader { block.backgroundColor = Self.headerFill }
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]
                    style.alignment = Self.alignment(columns[columnIndex].alignment)
                    let paragraph = NSMutableAttributedString(attributedString: cell)
                    if rowIndex < rows.count - 1 || columnIndex < row.cells.count - 1 {
                        paragraph.append(NSAttributedString(string: "\n", attributes: body))
                    }
                    paragraph.addAttribute(.paragraphStyle, value: style,
                                           range: NSRange(location: 0, length: paragraph.length))
                    out.append(paragraph)
                }
            }
            return out
        }

        private static let border = NSColor(white: 1, alpha: 0.28)
        private static let headerFill = NSColor(white: 1, alpha: 0.08)
        private static let horizontalPadding: CGFloat = 6
        private static let verticalPadding: CGFloat = 3

        private static func alignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> NSTextAlignment {
            switch alignment {
            case .center: .center
            case .right: .right
            case .left: .left
            @unknown default: .left
            }
        }
    }
}
