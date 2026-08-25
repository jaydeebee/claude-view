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
        default:
            return (sentenceCase(fallback), nil)
        }
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
            return ms < 1000 ? "\(Int(ms))ms" : String(format: "%.1fs", ms / 1000)
        case "local_command":
            return commandOutput(of: entry).map(firstLine)
        default:
            return entry.raw["content"]?.stringValue.map(firstLine)
        }
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

    static func expanded(for entry: TranscriptEntry) -> Expanded {
        switch entry.kind {
        case .attachment:
            let payload = entry.raw["attachment"]
            switch payload?["type"]?.stringValue {
            case "edited_text_file":
                // Post-edit content with line numbers; a true diff against
                // the ~/.claude/file-history backup is a future feature.
                if let snippet = payload?["snippet"]?.stringValue {
                    return .code(snippet)
                }
            case "queued_command":
                if let prompt = payload?["prompt"]?.stringValue {
                    return .text(prompt)
                }
            case "skill_listing":
                if let content = payload?["content"]?.stringValue {
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
        default:
            return .raw
        }
    }
}
