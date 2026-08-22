import ClaudeViewCore
import SwiftUI

/// Full block-level Markdown: fenced code stays vertical, headings have
/// weight, lists indent, tables grid. Used for assistant prose; prompts
/// and thinking keep whitespace-preserving inline rendering.
struct MarkdownBlockText: View {
    let text: String

    private static let displayLimit = 20_000

    var body: some View {
        let clipped = text.count > Self.displayLimit
        let shown = clipped ? String(text.prefix(Self.displayLimit)) : text
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownBlocks.parse(shown)) { block in
                MarkdownBlockView(block: block)
            }
            if clipped {
                Text("… \(text.count - Self.displayLimit) more characters — see raw entry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block.kind {
        case .paragraph:
            Text(block.content)
                .textSelection(.enabled)
        case .heading(let level):
            Text(block.content)
                .font(headingFont(level))
                .padding(.top, 2)
        case .code(let language):
            CodeBlockView(
                code: String(block.content.characters), language: language)
        case .listItem(let marker, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(block.content)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent - 1) * 16)
        case .blockquote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(block.content)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .divider:
            Divider()
        case .table(let table):
            MarkdownTableView(table: table)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        ScrollView(.horizontal) {
            Text(code)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5)))
        .overlay(alignment: .topTrailing) {
            if let language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .padding(.trailing, 8)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { cell in
                    Text(cell.element)
                        .font(.callout.weight(.semibold))
                }
            }
            Divider()
            ForEach(Array(table.rows.enumerated()), id: \.offset) { row in
                GridRow {
                    ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                        Text(cell.element)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.3)))
    }
}
