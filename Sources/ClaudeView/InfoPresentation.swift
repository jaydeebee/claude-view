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
            return payload["prompt"]?.stringValue.map(firstLine)
        case "date_change":
            return payload["newDate"]?.stringValue
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
            guard let ms = entry.raw["durationMs"]?.doubleValue else { return nil }
            return ms < 1000 ? "\(Int(ms))ms" : String(format: "%.1fs", ms / 1000)
        default:
            return entry.raw["content"]?.stringValue.map(firstLine)
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
