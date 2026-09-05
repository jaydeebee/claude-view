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
    /// True when the block sits inside a blockquote, whatever it is. A
    /// quoted list is still quoted, and so is a quoted fence — but the
    /// list and code branches answered first and returned, so anything
    /// inside a quote that was not a bare paragraph lost the quote
    /// entirely and rendered as ordinary body text.
    public let isQuoted: Bool

    public init(
        id: Int, kind: Kind, content: AttributedString, isQuoted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.isQuoted = isQuoted
    }
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
        let text = softenLabelBreaks(text)
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
            // CommonMark turns a soft break into a space, which folds a
            // hard-wrapped paragraph onto one line — the very thing block
            // rendering exists to prevent. Put the break back.
            if run.inlinePresentationIntent?.contains(.softBreak) == true {
                var newline = AttributedString("\n")
                newline.setAttributes(piece.runs.first?.attributes ?? .init())
                newline.inlinePresentationIntent = nil
                piece = newline
            }
            builder.add(piece, components: run.presentationIntent?.components ?? [])
        }
        builder.finish()
        return builder.blocks
    }

    /// Newlines inside a link or image label, replaced by the space
    /// CommonMark says they mean.
    ///
    /// This has to happen here, in the source text, because Foundation
    /// drops the character before the run stream exists: the softBreak
    /// repair above never sees it, and "[the full\nreport](url)" arrives
    /// as "the fullreport" — two words welded together, in the one place
    /// a reader is most likely to click.
    ///
    /// Fenced code is left alone, since a fence can contain anything and
    /// its newlines are load-bearing. The pattern is deliberately narrow:
    /// a bracketed run with no nested brackets, containing a newline,
    /// followed by the `(` or `[` that makes it a link rather than prose
    /// that happens to use brackets.
    static func softenLabelBreaks(_ text: String) -> String {
        guard text.contains("](") || text.contains("][") else { return text }

        var result: [String] = []
        var prose: [String] = []
        var inFence = false

        func flushProse() {
            guard !prose.isEmpty else { return }
            result.append(soften(prose.joined(separator: "\n")))
            prose.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushProse()
                result.append(line)
                inFence.toggle()
            } else if inFence {
                result.append(line)
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                // An indented code block is code without a fence to say
                // so, and its newlines and leading spaces are the content:
                // rewriting `let a = [foo` / `bar](baz)` into one line
                // destroys both, and can cost the block its indent and so
                // its code-ness entirely.
                flushProse()
                result.append(line)
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return result.joined(separator: "\n")
    }

    private static let labelBreak = try? NSRegularExpression(
        pattern: #"\[([^\[\]]*\n[^\[\]]*)\](?=[\(\[])"#)

    private static func soften(_ text: String) -> String {
        guard let labelBreak else { return text }
        let ns = text as NSString
        let matches = labelBreak.matches(
            in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        for match in matches {
            let whole = match.range
            out += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            let label = ns.substring(with: match.range(at: 1))
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            out += "[" + label + "]"
            cursor = whole.location + whole.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private struct Builder {
        var blocks: [MarkdownBlock] = []
        private var nextId = 0

        private var currentChain: [Int]?
        private var currentComponents: [PresentationIntent.IntentType] = []
        private var currentContent = AttributedString()
        /// Every list item that has already been given its marker. A set,
        /// not the previous one: an item's continuation paragraph gets no
        /// second bullet even when a nested sublist came between them,
        /// which is exactly when the old check forgot and gave it one.
        private var markedListItems: Set<Int> = []

        private var openTableIdentity: Int?
        private var openTableQuoted = false
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
                    openTableQuoted = Self.isQuoted(components)
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

        /// Quoting is passed in rather than read from a field set for the
        /// duration of a flush. It was a field, and tables — which never
        /// go through a flush, having their own path from `add` — came out
        /// unquoted: the field had already been reset by the time the
        /// table was emitted. An argument makes forgetting it a compile
        /// error rather than a missing bar.
        private mutating func append(
            _ kind: MarkdownBlock.Kind, _ content: AttributedString, quoted: Bool
        ) {
            blocks.append(
                MarkdownBlock(id: nextId, kind: kind, content: content, isQuoted: quoted))
            nextId += 1
        }

        private static func isQuoted(_ components: [PresentationIntent.IntentType]) -> Bool {
            components.contains {
                if case .blockQuote = $0.kind { return true } else { return false }
            }
        }

        private mutating func flushBlock() {
            defer {
                currentChain = nil
                currentComponents = []
                currentContent = AttributedString()
            }
            guard currentChain != nil else { return }
            let components = currentComponents
            let quoted = Self.isQuoted(components)

            if components.contains(where: {
                if case .thematicBreak = $0.kind { return true } else { return false }
            }) {
                append(.divider, AttributedString(), quoted: quoted)
                return
            }

            if let code = components.first(where: {
                if case .codeBlock = $0.kind { return true } else { return false }
            }), case .codeBlock(let hint) = code.kind {
                var text = String(currentContent.characters)
                if text.hasSuffix("\n") { text.removeLast() }
                let language = hint.flatMap { $0.isEmpty ? nil : $0 }
                append(.code(language: language), AttributedString(text), quoted: quoted)
                return
            }

            if let header = components.first(where: {
                if case .header = $0.kind { return true } else { return false }
            }), case .header(let level) = header.kind {
                append(.heading(level), currentContent, quoted: quoted)
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
                if !markedListItems.insert(components[itemIndex].identity).inserted {
                    marker = ""  // a continuation paragraph of an item already marked
                }
                append(
                    .listItem(marker: marker, indent: max(containers.count, 1)),
                    currentContent, quoted: quoted)
                return
            }

            if quoted {
                append(.blockquote, currentContent, quoted: true)
                return
            }

            if !currentContent.characters.isEmpty {
                append(.paragraph, currentContent, quoted: false)
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
                openTableQuoted = false
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
            append(.table(table), AttributedString(), quoted: openTableQuoted)
        }
    }
}
