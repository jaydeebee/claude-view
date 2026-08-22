import ClaudeViewCore
import SwiftUI

/// Skimmable JSON: syntax-colored tokens emitted straight from the parsed
/// tree, with keys padded to the widest sibling so values share a left
/// edge per object. Output stays valid JSON — the padding is just legal
/// whitespace after the colon.
enum JSONHighlight {
    /// Strings longer than this display truncated (full text remains
    /// available via Copy JSON, which uses the unstyled pretty print).
    static let stringDisplayLimit = 2_000

    static func attributed(_ value: JSONValue) -> AttributedString {
        var out = AttributedString()
        render(value, indent: 0, into: &out)
        return out
    }

    // MARK: Palette (adaptive to light/dark)

    private static let keyColor = Color.teal
    private static let stringColor = Color.green
    private static let numberColor = Color.purple
    private static let literalColor = Color.orange
    private static let punctuation = Color.secondary

    private static func colored(_ s: String, _ color: Color) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = color
        return a
    }

    private static func render(
        _ value: JSONValue, indent: Int, into out: inout AttributedString
    ) {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch value {
        case .null:
            out += colored("null", literalColor)
        case .bool(let b):
            out += colored(b ? "true" : "false", literalColor)
        case .number(let n):
            let text = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            out += colored(text, numberColor)
        case .string(let s):
            if s.count > Self.stringDisplayLimit {
                out += colored(JSONValue.quoted(String(s.prefix(Self.stringDisplayLimit))), stringColor)
                out += colored(" … +\(s.count - Self.stringDisplayLimit) chars", punctuation)
            } else {
                out += colored(JSONValue.quoted(s), stringColor)
            }
        case .array(let items):
            if items.isEmpty {
                out += colored("[]", punctuation)
                return
            }
            out += colored("[\n", punctuation)
            for (i, item) in items.enumerated() {
                out += AttributedString(childPad)
                render(item, indent: indent + 1, into: &out)
                out += colored(i == items.count - 1 ? "\n" : ",\n", punctuation)
            }
            out += colored(pad + "]", punctuation)
        case .object(let dict):
            if dict.isEmpty {
                out += colored("{}", punctuation)
                return
            }
            let keys = dict.keys.sorted()
            // The alignment that makes it glanceable: values share a left
            // edge within each object.
            let quotedKeys = keys.map { JSONValue.quoted($0) }
            let width = quotedKeys.map(\.count).max() ?? 0
            out += colored("{\n", punctuation)
            for (i, key) in keys.enumerated() {
                out += AttributedString(childPad)
                out += colored(quotedKeys[i], keyColor)
                out += colored(":", punctuation)
                out += AttributedString(
                    String(repeating: " ", count: width - quotedKeys[i].count + 1))
                render(dict[key]!, indent: indent + 1, into: &out)
                out += colored(i == keys.count - 1 ? "\n" : ",\n", punctuation)
            }
            out += colored(pad + "}", punctuation)
        }
    }
}
