import ClaudeViewCore
import Foundation

/// Titles and salient metadata for info rows — attachments and system
/// entries whose snake_case types deserve better than raw labels.
/// "edited_text_file" reads as "Edited Text File · ~/src/app/Foo.swift".
enum InfoPresentation {
    static func display(for entry: TranscriptEntry, fallback: String) -> (
        title: String, detail: String?
    ) {
        switch entry.kind {
        case .attachment:
            let payload = entry.raw["attachment"]
            let type = payload?["type"]?.stringValue ?? fallback
            return (humanize(type), attachmentDetail(type: type, payload: payload))
        case .system:
            let subtype = entry.subtype ?? "system"
            return (humanize(subtype), systemDetail(subtype: subtype, entry: entry))
        case .user:
            // An orphan tool result: the assembler surfaced it rather than
            // let it vanish with the call it cannot find, and the row is
            // about the result, so say what the result was.
            return (sentenceCase(fallback), toolResultText(of: entry).map(firstLine))
        default:
            return (sentenceCase(fallback), nil)
        }
    }

    /// The text carried by a user entry's tool_result blocks. Flattened the
    /// same way a paired result is, so an orphan reads like the row it
    /// would have been part of.
    static func toolResultText(of entry: TranscriptEntry) -> String? {
        let pieces = entry.contentBlocks.compactMap { block -> String? in
            guard case .toolResult(_, let content, _) = block else { return nil }
            let text = ContentBlock.flattenedText(of: content)
            return text.isEmpty ? nil : text
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    private static func attachmentDetail(type: String, payload: JSONValue?) -> String? {
        guard let payload else { return nil }
        switch type {
        case "edited_text_file":
            return payload["filename"]?.stringValue.map(abbreviatePath)
        case "queued_command":
            guard let prompt = payload["prompt"]?.stringValue else { return nil }
            // A queued task-notification's first line is an XML tag; its
            // summary is the part worth a detail slot.
            if prompt.contains("<task-notification>"),
                let summary = LocalCommandMarkup.tagContent("summary", in: prompt)
            {
                return firstLine(summary)
            }
            return firstLine(prompt)
        case "date_change":
            return payload["newDate"]?.stringValue
        case "total_tokens_reminder":
            return payload["text"]?.stringValue.flatMap {
                LocalCommandMarkup.tagContent("total_tokens", in: $0)
            }
        case "task_reminder":
            if let count = payload["itemCount"]?.intValue, count > 0 {
                return "\(count) open task\(count == 1 ? "" : "s")"
            }
            return nil
        default:
            for key in ["filename", "file_path", "path", "content", "prompt", "name"] {
                if let value = payload[key]?.stringValue, !value.isEmpty {
                    return firstLine(abbreviatePath(value))
                }
            }
            return nil
        }
    }

    private static func systemDetail(subtype: String, entry: TranscriptEntry) -> String? {
        switch subtype {
        case "turn_duration":
            // JSON happily carries -1e19 here; Int(_:) would trap on it.
            guard let ms = entry.raw["durationMs"]?.doubleValue,
                ms.isFinite, ms >= 0
            else { return nil }
            return durationText(milliseconds: ms)
        case "local_command":
            return commandOutput(of: entry).map(firstLine)
        default:
            return entry.raw["content"]?.stringValue.map(firstLine)
        }
    }

    /// "840ms", "4.5s", "1m 15s", "2h 6m". A turn that takes three
    /// quarters of an hour read as "2661.7s" — a number nobody converts in
    /// their head, on the row that exists to say how long you waited.
    static func durationText(milliseconds ms: Double) -> String {
        if ms < 1000 { return "\(Int(ms))ms" }
        // Clamped, because `Int(_:)` traps on a Double too large for it and
        // this number comes out of a file the app does not control. The
        // caller's guard rejects non-finite and negative values, which is
        // where the old single conversion needed help; adding a second one
        // on this branch quietly reopened the same hole for 1e25.
        let total = Int(min(ms / 1000, 1e9))
        if total < 60 { return String(format: "%.1fs", ms / 1000) }
        let (hours, minutes, seconds) = (total / 3600, (total % 3600) / 60, total % 60)
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds)s"
    }

    /// Inner text of the stdout/stderr envelope on local_command entries.
    static func commandOutput(of entry: TranscriptEntry) -> String? {
        guard let content = entry.raw["content"]?.stringValue else { return nil }
        let out = LocalCommandMarkup.tagContent("local-command-stdout", in: content)
        let err = LocalCommandMarkup.tagContent("local-command-stderr", in: content)
        let joined = [out, err].compactMap { $0 }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// The one value a bookkeeping sidecar is really carrying — "plan"
    /// for a permission-mode stamp, the title for ai-title, and for
    /// types this build has never met, the first scalar field that
    /// isn't routing plumbing.
    static func bookkeepingDetail(for entry: TranscriptEntry) -> String? {
        let raw = entry.raw
        switch raw["type"]?.stringValue {
        case "mode":
            return raw["mode"]?.stringValue
        case "permission-mode":
            return raw["permissionMode"]?.stringValue
        case "ai-title":
            return raw["aiTitle"]?.stringValue
        case "last-prompt":
            return raw["lastPrompt"]?.stringValue.map(firstLine)
        case "queue-operation":
            let parts = [
                raw["operation"]?.stringValue,
                raw["content"]?.stringValue.map(firstLine),
            ].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "file-history-snapshot":
            return raw["messageId"]?.stringValue
        case "file-history-delta":
            return raw["trackingPath"]?.stringValue.map(abbreviatePath)
        default:
            let plumbing: Set<String> = ["type", "sessionId", "leafUuid", "timestamp"]
            guard let fields = raw.objectValue else { return nil }
            for key in fields.keys.sorted() where !plumbing.contains(key) {
                switch fields[key] {
                case .string(let s):
                    return "\(key): \"\(firstLine(s))\""
                case .bool(let b):
                    return "\(key): \(b)"
                case .integer(let i):
                    return "\(key): \(i)"
                case .number(let n):
                    return "\(key): \(n)"
                default:
                    continue
                }
            }
            return nil
        }
    }

    static func humanize(_ label: String) -> String {
        guard label.contains("_") || label.contains("-") else {
            return sentenceCase(label)
        }
        return label
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func sentenceCase(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    private static func firstLine(_ s: String) -> String {
        String(s.prefix(while: { $0 != "\n" }).prefix(100))
    }

    private static func abbreviatePath(_ s: String) -> String {
        s.hasPrefix("/") ? (s as NSString).abbreviatingWithTildeInPath : s
    }
}

extension InfoPresentation {
    /// What expansion reveals: readable payload where the type has one,
    /// the raw entry otherwise. (Full JSON stays on Inspect Entry.)
    enum Expanded {
        case code(String)
        case text(String)
        case raw
    }

    /// A payload string worth rendering: present and not empty. An empty
    /// one is not readable content, and returning it as such draws an
    /// empty box — a row that opens onto nothing looks broken, where the
    /// raw entry at least shows that the field really is "".
    private static func readable(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    static func expanded(for entry: TranscriptEntry) -> Expanded {
        switch entry.kind {
        case .attachment:
            let payload = entry.raw["attachment"]
            switch payload?["type"]?.stringValue {
            case "edited_text_file":
                // Post-edit content with line numbers; a true diff against
                // the ~/.claude/file-history backup is a future feature.
                if let snippet = readable(payload?["snippet"]) {
                    return .code(snippet)
                }
            case "queued_command":
                if let prompt = readable(payload?["prompt"]) {
                    return .text(prompt)
                }
            case "skill_listing":
                if let content = readable(payload?["content"]) {
                    return .text(content)
                }
            case "agent_listing_delta", "deferred_tools_delta":
                if let lines = payload?["addedLines"]?.arrayValue {
                    let joined = lines.compactMap(\.stringValue).joined(separator: "\n")
                    if !joined.isEmpty { return .text(joined) }
                }
            default:
                break
            }
            return .raw
        case .system:
            if entry.subtype == "local_command", let output = commandOutput(of: entry) {
                return .text(output)
            }
            if let content = entry.raw["content"]?.stringValue, !content.isEmpty {
                return .text(content)
            }
            return .raw
        case .user:
            if let text = toolResultText(of: entry) { return .text(text) }
            return .raw
        default:
            return .raw
        }
    }
}
