import ClaudeViewCore
import Foundation

/// How a tool call introduces itself in a collapsed row.
enum ToolPresentation {
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "NotebookEdit": "pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "Task", "Agent": "person.2"
        case "WebFetch", "WebSearch": "globe"
        case "TodoWrite", "TaskCreate", "TaskUpdate": "checklist"
        case "AskUserQuestion": "questionmark.bubble"
        case "Skill": "wand.and.stars"
        default: "wrench.and.screwdriver"
        }
    }

    /// One-line gist of the input: the command, the file, the pattern —
    /// whichever field carries the intent for this tool.
    static func summary(name: String, input: JSONValue) -> String {
        let candidates: [String]
        switch name {
        case "Bash": candidates = ["description", "command"]
        case "Read", "Edit", "Write": candidates = ["file_path"]
        case "Grep", "Glob": candidates = ["pattern"]
        case "Task", "Agent": candidates = ["description", "prompt"]
        case "WebFetch": candidates = ["url"]
        case "WebSearch": candidates = ["query"]
        case "Skill": candidates = ["skill"]
        default: candidates = ["description", "path", "query", "command"]
        }
        for key in candidates {
            if let value = input[key]?.stringValue, !value.isEmpty {
                return firstLine(of: abbreviatePath(head(of: value)))
            }
        }
        // Fall back to the first short string field the input has.
        if let object = input.objectValue {
            for key in object.keys.sorted() {
                if let value = object[key]?.stringValue, !value.isEmpty {
                    return firstLine(of: "\(key): \(head(of: value))")
                }
            }
        }
        return ""
    }

    /// Enough of a value to answer any question `firstLine` can ask of it.
    ///
    /// A summary is at most 120 characters of the first line, but the
    /// value handed in can be a whole file: the unknown-tool fallback
    /// interpolated all of it into a new string, and abbreviatePath
    /// bridged all of it to NSString, before either of those cut it to
    /// 120. Everything past this prefix is either behind a newline or
    /// behind the clip, so taking it changes no output.
    private static func head(of s: String) -> String {
        String(s.prefix(240))
    }

    private static func firstLine(of s: String) -> String {
        let line = s.prefix(while: { $0 != "\n" })
        return String(line.prefix(120))
    }

    private static func abbreviatePath(_ s: String) -> String {
        s.hasPrefix("/") ? (s as NSString).abbreviatingWithTildeInPath : s
    }

    /// Input rendered as aligned `key: value` lines for the expanded body.
    static func inputLines(_ input: JSONValue, valueLimit: Int = 500) -> [(String, String)] {
        let limits = JSONRenderOptions(stringLimit: valueLimit, maxContainerItems: 50)
        guard let object = input.objectValue else {
            let flat = input.prettyPrinted(options: limits)
            return flat == "null" ? [] : [("input", clipped(flat, to: valueLimit))]
        }
        return object.keys.sorted().map { key in
            let value = object[key] ?? .null
            // Rendered with the limits applied rather than in full: a
            // nested value of any size now costs what is shown of it.
            let rendered = value.stringValue ?? value.prettyPrinted(options: limits)
            return (key, clipped(rendered, to: valueLimit))
        }
    }

    /// Clips without measuring: `dropFirst` advances over the limit, not
    /// the string, where `count > limit` walked every character of the
    /// value — which for a written file is the whole file, on every body
    /// pass, to decide whether to show 500 characters of it.
    private static func clipped(_ s: String, to limit: Int) -> String {
        guard !s.dropFirst(limit).isEmpty else { return s }
        return String(s.prefix(limit)) + "… (\(s.utf8.count) bytes)"
    }
}
