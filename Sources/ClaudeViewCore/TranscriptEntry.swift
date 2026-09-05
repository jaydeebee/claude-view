import Foundation

/// One line of a session transcript (`<session-uuid>.jsonl`).
///
/// Claude Code writes one entry per content block: a single assistant API
/// message arrives as several consecutive entries sharing `message.id`.
/// Entries carry `parentUuid` lineage, but that is not a strict chain —
/// render in file order and pair related entries by their id fields.
public struct TranscriptEntry: Sendable, Identifiable {
    /// Entry kinds observed in real transcripts. The format is internal to
    /// Claude Code; anything unrecognized lands in `.unknown` and still renders.
    public enum Kind: Equatable, Sendable {
        case user
        case assistant
        case system
        case attachment
        case summary
        case aiTitle
        case lastPrompt
        case mode
        case permissionMode
        case queueOperation
        case fileHistorySnapshot
        case fileHistoryDelta
        case unknown(String)

        init(typeString: String) {
            switch typeString {
            case "user": self = .user
            case "assistant": self = .assistant
            case "system": self = .system
            case "attachment": self = .attachment
            case "summary": self = .summary
            case "ai-title": self = .aiTitle
            case "last-prompt": self = .lastPrompt
            case "mode": self = .mode
            case "permission-mode": self = .permissionMode
            case "queue-operation": self = .queueOperation
            case "file-history-snapshot": self = .fileHistorySnapshot
            case "file-history-delta": self = .fileHistoryDelta
            default: self = .unknown(typeString)
            }
        }
    }

    public let raw: JSONValue
    public let kind: Kind

    /// Position in the file, used as a stable identity fallback for entries
    /// without a uuid (sidecars).
    public let index: Int

    public init(raw: JSONValue, index: Int) {
        self.raw = raw
        self.kind = Kind(typeString: raw["type"]?.stringValue ?? "")
        self.index = index
    }

    public init(line: Data, index: Int) throws {
        self.init(raw: try JSONValue(data: line), index: index)
    }

    // MARK: Common fields

    public var id: String { uuid ?? "#\(index)" }
    public var uuid: String? { raw["uuid"]?.stringValue }
    public var parentUuid: String? { raw["parentUuid"]?.stringValue }
    public var sessionId: String? { raw["sessionId"]?.stringValue }
    public var isSidechain: Bool { raw["isSidechain"]?.boolValue ?? false }
    /// Meta entries are harness-injected context, not something the user typed.
    public var isMeta: Bool { raw["isMeta"]?.boolValue ?? false }
    public var subtype: String? { raw["subtype"]?.stringValue }

    public var timestamp: Date? {
        raw["timestamp"]?.stringValue.flatMap(Self.parseTimestamp)
    }

    // MARK: Message projection (user/assistant entries)

    /// `message.id` — shared by all entries split from one assistant API message.
    public var messageId: String? { raw["message"]?["id"]?.stringValue }

    public var contentBlocks: [ContentBlock] {
        guard let message = raw["message"] else { return [] }
        // User prompts may be a plain string instead of a block array.
        if let text = message["content"]?.stringValue {
            return [.text(text)]
        }
        guard let blocks = message["content"]?.arrayValue else { return [] }
        return blocks.map(ContentBlock.init(raw:))
    }

    /// Structured result data attached alongside a tool_result block.
    public var toolUseResult: JSONValue? { raw["toolUseResult"] }

    /// Token usage reported on assistant entries.
    public var usage: JSONValue? { raw["message"]?["usage"] }

    // MARK: Sidecar payloads

    public var aiTitle: String? { raw["aiTitle"]?.stringValue }
    public var lastPrompt: String? { raw["lastPrompt"]?.stringValue }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }
}

/// One element of a message's `content` array.
public enum ContentBlock: Sendable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: JSONValue, isError: Bool)
    case other(JSONValue)

    init(raw: JSONValue) {
        switch raw["type"]?.stringValue {
        case "text":
            self = .text(raw["text"]?.stringValue ?? "")
        case "thinking":
            self = .thinking(raw["thinking"]?.stringValue ?? "")
        case "tool_use":
            self = .toolUse(
                id: raw["id"]?.stringValue ?? "",
                name: raw["name"]?.stringValue ?? "?",
                input: raw["input"] ?? .null)
        case "tool_result":
            self = .toolResult(
                toolUseId: raw["tool_use_id"]?.stringValue ?? "",
                content: raw["content"] ?? .null,
                isError: raw["is_error"]?.boolValue ?? false)
        default:
            self = .other(raw)
        }
    }

    /// Plain-text form of a tool_result's `content`, which may be a string or
    /// an array of text/image blocks.
    public static func flattenedText(of content: JSONValue) -> String {
        if let s = content.stringValue { return s }
        guard let items = content.arrayValue else { return "" }
        return items.compactMap { item in
            switch item["type"]?.stringValue {
            case "text": return item["text"]?.stringValue
            case "image": return "[image]"
            default: return nil
            }
        }.joined(separator: "\n")
    }
}
