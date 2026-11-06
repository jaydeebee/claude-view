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
        guard let attributed = attributed(text, syntax: .full) else {
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

    /// Parses Markdown with home-directory tildes kept out of strikethrough.
    ///
    /// Foundation's parser takes GFM's single-tilde strikethrough, and a
    /// tilde with punctuation on both sides can both open and close one —
    /// which is exactly what `~/` is. So `(~/a) and (~/b)` came out as
    /// "(", a struck "/a) and (", then "/b)": the tildes gone and the
    /// prose between two paths crossed out. Claude names home-relative
    /// paths constantly, and not always inside backticks.
    ///
    /// A lone `~` before `/` is swapped for a stand-in before parsing and
    /// put back after. Not a backslash escape: a backslash is literal in
    /// code spans, code blocks and autolinks, so escaping would need to
    /// know where those are — the parser's job, not ours. The stand-in is
    /// SWUNG DASH, punctuation like the tilde it replaces, so the flanking
    /// rules that decide `*` and `_` emphasis around it see the same
    /// thing; a letter-class stand-in changed emphasis on its neighbours.
    /// Text that already contains a swung dash is parsed as is rather than
    /// risk turning the author's own into tildes.
    ///
    /// `~~struck~~`, `~word~` and `~~~` fences are untouched: only a run of
    /// exactly one tilde, followed by a slash, and not backslash-escaped.
    public static func attributed(
        _ text: String, syntax: AttributedString.MarkdownParsingOptions.InterpretedSyntax
    ) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: syntax,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let guarded = guardHomeTildes(text) else {
            return try? AttributedString(markdown: text, options: options)
        }
        guard var result = try? AttributedString(markdown: guarded, options: options) else {
            return nil
        }
        restoreHomeTildes(in: &result)
        return result
    }

    static let tildeStandIn: Character = "\u{2053}"
    private static let encodedStandIn = "%E2%81%93"

    /// The text with each guarded tilde swapped for the stand-in, or nil
    /// when there is nothing to guard (or the stand-in is already taken).
    static func guardHomeTildes(_ text: String) -> String? {
        guard text.contains("~/"), !text.contains(tildeStandIn) else { return nil }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var previous: Character?
        var escaped = false
        var iterator = Array(text)[...]
        while let c = iterator.popFirst() {
            defer { previous = c }
            if escaped {
                escaped = false
                out.append(c)
                continue
            }
            if c == "\\" {
                escaped = true
                out.append(c)
                continue
            }
            if c == "~", previous != "~", iterator.first == "/" {
                out.append(tildeStandIn)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Puts the tildes back: in the text, and in link destinations, where
    /// the parser has already percent-encoded the stand-in.
    static func restoreHomeTildes(in attributed: inout AttributedString) {
        // From the top each time: a mutation invalidates every index, and
        // each pass removes the stand-in it found.
        while let found = attributed.characters.firstIndex(of: tildeStandIn) {
            let next = attributed.characters.index(after: found)
            attributed.characters.replaceSubrange(found..<next, with: "~")
        }
        for run in attributed.runs {
            if let link = run.link, link.absoluteString.contains(encodedStandIn) {
                attributed[run.range].link = URL(
                    string: link.absoluteString.replacingOccurrences(of: encodedStandIn, with: "~"))
            }
        }
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
