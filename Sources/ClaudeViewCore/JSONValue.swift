import Foundation

/// A fully parsed, immutable JSON tree.
///
/// Transcript entries are decoded into this rather than into Codable structs
/// because the format is internal to Claude Code and shifts between releases.
/// Typed accessors project the fields we understand; everything else stays
/// intact for the raw inspector.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// Integer-typed source values stay exact — ids and timestamps must
    /// never round through Double on their way to a "ground truth" view.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = Self.wrap(obj)
    }

    private static func wrap(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // CFBoolean is an NSNumber; distinguish true booleans from 0/1.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            if !CFNumberIsFloatType(n) {
                // Unsigned values past Int64.max can't be held exactly.
                if String(cString: n.objCType) == "Q", n.uint64Value > UInt64(Int64.max) {
                    return .number(n.doubleValue)
                }
                return .integer(n.int64Value)
            }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(wrap))
        case let d as [String: Any]:
            return .object(d.mapValues(wrap))
        default:
            return .null
        }
    }

    // MARK: Traversal

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) {
            return items[index]
        }
        return nil
    }

    // MARK: Typed accessors

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .integer(let i): return Double(i)
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let i): return Int(exactly: i)
        case .number(let n): return Int(exactly: n.rounded(.towardZero))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }
}

// MARK: - Rendering

/// One colored-or-plain span of rendered JSON. The pretty printer and the
/// highlighted view consume the same token stream, so they can never
/// silently diverge.
public enum JSONToken: Sendable {
    case punctuation(String)
    case key(String)
    case string(String)
    case number(String)
    case literal(String)
    /// Display-only truncation notes — never present in untruncated output.
    case note(String)

    public var text: String {
        switch self {
        case .punctuation(let s), .key(let s), .string(let s),
            .number(let s), .literal(let s), .note(let s):
            return s
        }
    }
}

public struct JSONRenderOptions: Sendable {
    /// Truncate string leaves past this many characters (display only).
    public var stringLimit: Int?
    /// Cap array elements / object fields per container (display only).
    public var maxContainerItems: Int?
    /// Pad keys to the widest sibling so values share a left edge.
    public var alignValues: Bool

    public init(
        stringLimit: Int? = nil,
        maxContainerItems: Int? = nil,
        alignValues: Bool = false
    ) {
        self.stringLimit = stringLimit
        self.maxContainerItems = maxContainerItems
        self.alignValues = alignValues
    }
}

extension JSONValue {
    /// Stable, human-readable form; also the Copy JSON payload. Full
    /// fidelity — no truncation, no alignment padding.
    public var prettyPrinted: String {
        var out = ""
        renderTokens { out += $0.text }
        return out
    }

    public func renderTokens(
        options: JSONRenderOptions = JSONRenderOptions(),
        emit: (JSONToken) -> Void
    ) {
        renderTokens(indent: 0, options: options, emit: emit)
    }

    private func renderTokens(
        indent: Int, options: JSONRenderOptions, emit: (JSONToken) -> Void
    ) {
        switch self {
        case .null:
            emit(.literal("null"))
        case .bool(let b):
            emit(.literal(b ? "true" : "false"))
        case .integer(let i):
            emit(.number(String(i)))
        case .number(let n):
            emit(.number(Self.doubleText(n)))
        case .string(let s):
            if let limit = options.stringLimit {
                let count = s.count
                if count > limit {
                    emit(.string(Self.quoted(String(s.prefix(limit)))))
                    emit(.note(" … +\(count - limit) chars"))
                    return
                }
            }
            emit(.string(Self.quoted(s)))
        case .array(let items):
            if items.isEmpty {
                emit(.punctuation("[]"))
                return
            }
            let pad = String(repeating: "  ", count: indent)
            let childPad = pad + "  "
            let shown = options.maxContainerItems.map { min($0, items.count) } ?? items.count
            emit(.punctuation("[\n"))
            for (i, item) in items.prefix(shown).enumerated() {
                emit(.punctuation(childPad))
                item.renderTokens(indent: indent + 1, options: options, emit: emit)
                emit(.punctuation(i == shown - 1 && items.count == shown ? "\n" : ",\n"))
            }
            if items.count > shown {
                emit(.note(childPad + "… +\(items.count - shown) more items\n"))
            }
            emit(.punctuation(pad + "]"))
        case .object(let dict):
            if dict.isEmpty {
                emit(.punctuation("{}"))
                return
            }
            let pad = String(repeating: "  ", count: indent)
            let childPad = pad + "  "
            let keys = dict.keys.sorted()
            let shown = options.maxContainerItems.map { min($0, keys.count) } ?? keys.count
            let quotedKeys = keys.prefix(shown).map { Self.quoted($0) }
            let width = options.alignValues ? (quotedKeys.map(\.count).max() ?? 0) : 0
            emit(.punctuation("{\n"))
            for (i, key) in keys.prefix(shown).enumerated() {
                emit(.punctuation(childPad))
                emit(.key(quotedKeys[i]))
                let gap =
                    options.alignValues
                    ? String(repeating: " ", count: width - quotedKeys[i].count + 1)
                    : " "
                emit(.punctuation(":" + gap))
                dict[key]!.renderTokens(indent: indent + 1, options: options, emit: emit)
                emit(.punctuation(i == shown - 1 && keys.count == shown ? "\n" : ",\n"))
            }
            if keys.count > shown {
                emit(.note(childPad + "… +\(keys.count - shown) more fields\n"))
            }
            emit(.punctuation(pad + "}"))
        }
    }

    private static func doubleText(_ n: Double) -> String {
        // Negative zero keeps its sign; whole doubles print without ".0".
        if n == n.rounded(), abs(n) < 1e15, !(n == 0 && n.sign == .minus) {
            return String(Int64(n))
        }
        return String(n)
    }

    public static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            // Line/paragraph separators force visual breaks; bidi controls
            // can visually reorder the display (Trojan Source). Escape both
            // so the "ground truth" view can't lie about its bytes.
            case "\u{0085}", "\u{2028}", "\u{2029}",
                "\u{200E}", "\u{200F}",
                "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
                "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}":
                out += String(format: "\\u%04x", ch.value)
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
