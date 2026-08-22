import Foundation

/// A GFM table extracted from block structure.
public struct MarkdownTable {
    public var header: [AttributedString] = []
    public var rows: [[AttributedString]] = []
}

/// One block of rendered Markdown, in document order.
public struct MarkdownBlock: Identifiable {
    public enum Kind {
        case paragraph
        case heading(Int)
        case code(language: String?)
        /// `marker` is "•" or "1." etc.; empty for continuation paragraphs
        /// inside the same list item. `indent` is the nesting level, from 1.
        case listItem(marker: String, indent: Int)
        case blockquote
        case divider
        case table(MarkdownTable)
    }

    public let id: Int
    public let kind: Kind
    public let content: AttributedString
}

/// Block-level Markdown parsing without leaving Foundation.
///
/// `AttributedString(markdown:)` with `.full` syntax already computes block
/// structure as PresentationIntent runs — SwiftUI's Text just ignores it.
/// This walks the runs into typed blocks a view can lay out properly.
/// Born of a real bug: inline-only parsing turns a code fence into a code
/// span, and CommonMark folds a span's newlines into spaces, hoisting whole
/// commit listings onto one line.
public enum MarkdownBlocks {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let attributed = try? AttributedString(markdown: text, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, content: AttributedString(text))]
        }

        var builder = Builder()
        for run in attributed.runs {
            var piece = AttributedString(attributed[run.range])
            piece.presentationIntent = nil
            builder.add(piece, components: run.presentationIntent?.components ?? [])
        }
        builder.finish()
        return builder.blocks
    }

    private struct Builder {
        var blocks: [MarkdownBlock] = []
        private var nextId = 0

        private var currentChain: [Int]?
        private var currentComponents: [PresentationIntent.IntentType] = []
        private var currentContent = AttributedString()
        private var previousListItemIdentity: Int?

        private var openTableIdentity: Int?
        private var tableColumnCount = 0
        private var tableHeaderCells: [Int: AttributedString] = [:]
        private var tableRowCells: [Int: [Int: AttributedString]] = [:]

        mutating func add(_ piece: AttributedString, components: [PresentationIntent.IntentType]) {
            if let table = components.first(where: {
                if case .table = $0.kind { return true } else { return false }
            }) {
                if openTableIdentity != table.identity {
                    flushBlock()
                    flushTable()
                    openTableIdentity = table.identity
                    if case .table(let columns) = table.kind {
                        tableColumnCount = columns.count
                    }
                }
                addTableCell(piece, components: components)
                return
            }
            flushTable()

            let chain = components.map(\.identity)
            if chain != currentChain {
                flushBlock()
                currentChain = chain
                currentComponents = components
            }
            currentContent += piece
        }

        mutating func finish() {
            flushBlock()
            flushTable()
        }

        private mutating func append(_ kind: MarkdownBlock.Kind, _ content: AttributedString) {
            blocks.append(MarkdownBlock(id: nextId, kind: kind, content: content))
            nextId += 1
        }

        private mutating func flushBlock() {
            defer {
                currentChain = nil
                currentComponents = []
                currentContent = AttributedString()
            }
            guard currentChain != nil else { return }
            let components = currentComponents
            let previousListItem = previousListItemIdentity
            previousListItemIdentity = nil

            if components.contains(where: {
                if case .thematicBreak = $0.kind { return true } else { return false }
            }) {
                append(.divider, AttributedString())
                return
            }

            if let code = components.first(where: {
                if case .codeBlock = $0.kind { return true } else { return false }
            }), case .codeBlock(let hint) = code.kind {
                var text = String(currentContent.characters)
                if text.hasSuffix("\n") { text.removeLast() }
                let language = hint.flatMap { $0.isEmpty ? nil : $0 }
                append(.code(language: language), AttributedString(text))
                return
            }

            if let header = components.first(where: {
                if case .header = $0.kind { return true } else { return false }
            }), case .header(let level) = header.kind {
                append(.heading(level), currentContent)
                return
            }

            if let itemIndex = components.firstIndex(where: {
                if case .listItem = $0.kind { return true } else { return false }
            }), case .listItem(let ordinal) = components[itemIndex].kind {
                let containers = components.filter {
                    switch $0.kind {
                    case .orderedList, .unorderedList: return true
                    default: return false
                    }
                }
                // Components run innermost-first; the item's own container is
                // the nearest list after it in the chain.
                let container =
                    components[(itemIndex + 1)...].first {
                        switch $0.kind {
                        case .orderedList, .unorderedList: return true
                        default: return false
                        }
                    } ?? containers.first
                var marker = "•"
                if case .orderedList = container?.kind { marker = "\(ordinal)." }
                if previousListItem == components[itemIndex].identity { marker = "" }
                previousListItemIdentity = components[itemIndex].identity
                append(
                    .listItem(marker: marker, indent: max(containers.count, 1)),
                    currentContent)
                return
            }

            if components.contains(where: {
                if case .blockQuote = $0.kind { return true } else { return false }
            }) {
                append(.blockquote, currentContent)
                return
            }

            if !currentContent.characters.isEmpty {
                append(.paragraph, currentContent)
            }
        }

        private mutating func addTableCell(
            _ piece: AttributedString, components: [PresentationIntent.IntentType]
        ) {
            var columnIndex: Int?
            var rowIndex: Int?
            var isHeader = false
            for component in components {
                switch component.kind {
                case .tableCell(let index): columnIndex = index
                case .tableRow(let index): rowIndex = index
                case .tableHeaderRow: isHeader = true
                default: break
                }
            }
            guard let columnIndex else { return }
            if isHeader {
                tableHeaderCells[columnIndex, default: AttributedString()] += piece
            } else if let rowIndex {
                tableRowCells[rowIndex, default: [:]][columnIndex, default: AttributedString()]
                    += piece
            }
        }

        private mutating func flushTable() {
            guard openTableIdentity != nil else { return }
            defer {
                openTableIdentity = nil
                tableColumnCount = 0
                tableHeaderCells = [:]
                tableRowCells = [:]
            }
            let columns = max(
                tableColumnCount,
                (tableHeaderCells.keys.max() ?? -1) + 1,
                (tableRowCells.values.flatMap(\.keys).max() ?? -1) + 1)
            guard columns > 0 else { return }

            var table = MarkdownTable()
            table.header = (0..<columns).map { tableHeaderCells[$0] ?? AttributedString() }
            for row in tableRowCells.keys.sorted() {
                let cells = tableRowCells[row] ?? [:]
                table.rows.append((0..<columns).map { cells[$0] ?? AttributedString() })
            }
            append(.table(table), AttributedString())
        }
    }
}
