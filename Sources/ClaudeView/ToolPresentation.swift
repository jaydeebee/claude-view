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
                return firstLine(of: abbreviatePath(value))
            }
        }
        // Fall back to the first short string field the input has.
        if let object = input.objectValue {
            for key in object.keys.sorted() {
                if let value = object[key]?.stringValue, !value.isEmpty {
                    return firstLine(of: "\(key): \(value)")
                }
            }
        }
        return ""
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
        guard let object = input.objectValue else {
            let flat = input.prettyPrinted
            return flat == "null" ? [] : [("input", String(flat.prefix(valueLimit)))]
        }
        return object.keys.sorted().map { key in
            let value = object[key] ?? .null
            let rendered = value.stringValue ?? value.prettyPrinted
            let clipped =
                rendered.count > valueLimit
                ? rendered.prefix(valueLimit) + "… (\(rendered.count) chars)"
                : Substring(rendered)
            return (key, String(clipped))
        }
    }
}
