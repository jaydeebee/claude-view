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
        if case .number(let n) = self { return n }
        return nil
    }

    public var intValue: Int? {
        doubleValue.map { Int($0) }
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

    // MARK: Rendering

    /// Stable, human-readable form for the raw inspector.
    public var prettyPrinted: String {
        var out = ""
        render(into: &out, indent: 0)
        return out
    }

    private func render(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let childPad = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let n):
            out += n == n.rounded() && abs(n) < 1e15
                ? String(Int64(n)) : String(n)
        case .string(let s):
            out += Self.quoted(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += childPad
                item.render(into: &out, indent: indent + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            out += "{\n"
            let keys = dict.keys.sorted()
            for (i, key) in keys.enumerated() {
                out += childPad + Self.quoted(key) + ": "
                dict[key]!.render(into: &out, indent: indent + 1)
                out += i == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
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
