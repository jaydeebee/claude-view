import SwiftUI

/// Markdown-ish text: inline styling (bold, code, links) with whitespace
/// preserved. Full block rendering — real code fences, lists, tables —
/// is a look-and-feel iteration for later.
struct MarkdownText: View {
    let text: String

    /// SwiftUI Text struggles far earlier than the parser does; clip
    /// pathological blocks and say so.
    private static let displayLimit = 20_000

    var body: some View {
        let clipped = text.count > Self.displayLimit
        let shown = clipped ? String(text.prefix(Self.displayLimit)) : text
        VStack(alignment: .leading, spacing: 4) {
            Text(attributed(shown))
                .textSelection(.enabled)
            if clipped {
                Text("… \(text.count - Self.displayLimit) more characters — see raw entry")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
