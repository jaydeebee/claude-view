import ClaudeViewCore
import SwiftUI

/// Skimmable JSON: the shared token walker does the formatting (aligned
/// values, truncated giants); this just paints the tokens. Copy JSON uses
/// the same walker without display options, so screen and clipboard can't
/// structurally diverge.
enum JSONHighlight {
    static let stringDisplayLimit = 2_000
    static let containerItemLimit = 500

    static func attributed(_ value: JSONValue) -> AttributedString {
        let options = JSONRenderOptions(
            stringLimit: Self.stringDisplayLimit,
            maxContainerItems: Self.containerItemLimit,
            alignValues: true)
        var out = AttributedString()
        value.renderTokens(options: options) { token in
            var piece = AttributedString(token.text)
            piece.foregroundColor = color(for: token)
            out += piece
        }
        return out
    }

    private static func color(for token: JSONToken) -> Color {
        switch token {
        case .punctuation, .note: .secondary
        case .key: .teal
        case .string: .primary
        case .number: .purple
        case .literal: .orange
        }
    }
}
