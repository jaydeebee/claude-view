import Foundation

/// Cheap glances at a transcript without reading the whole file — sidebar
/// rows need a title for sessions that may be tens of megabytes.
public enum TranscriptPeek {
    /// Best-effort title from the tail of the file: Claude Code appends
    /// `ai-title` sidecars as a session progresses, and `last-prompt` is a
    /// serviceable fallback. Reads at most `window` bytes.
    public static func quickTitle(url: URL, window: Int = 1 << 16) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd()
        else { return nil }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty {
            lines.removeFirst()  // partial line cut by the window
        }
        var fallback: String?
        for line in lines.reversed() {
            guard let entry = try? TranscriptEntry(line: Data(line), index: 0) else {
                continue
            }
            if let title = entry.aiTitle {
                return title
            }
            if fallback == nil, let prompt = entry.lastPrompt {
                fallback = String(prompt.prefix(80))
            }
        }
        return fallback
    }
}
