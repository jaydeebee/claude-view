import Foundation

/// Context-size facts from the tail of a transcript: what the API last
/// saw as the prompt, when, and which cache TTL the harness bought.
public struct ContextUsage: Sendable, Equatable {
    /// input + cache_read + cache_creation of the last assistant turn —
    /// the tokens a cache-cold resume would reprocess.
    public let contextTokens: Int64
    /// When that turn happened; the cache clock (re)starts here.
    public let at: Date
    /// Seconds the prompt cache lives past its last use.
    public let cacheTTL: TimeInterval

    public init(contextTokens: Int64, at: Date, cacheTTL: TimeInterval) {
        self.contextTokens = contextTokens
        self.at = at
        self.cacheTTL = cacheTTL
    }

    /// The cache is presumed warm until TTL past the last use. A
    /// heuristic, not a promise: a harness upgrade between sessions
    /// breaks the cached prefix early.
    public var warmUntil: Date { at.addingTimeInterval(cacheTTL) }
}

/// Cheap glances at a transcript without reading the whole file — sidebar
/// rows need a title for sessions that may be tens of megabytes.
public enum TranscriptPeek {
    /// Best-effort title from the tail of the file: Claude Code appends
    /// `ai-title` sidecars as a session progresses, and `last-prompt` is a
    /// serviceable fallback. Reads at most `window` bytes.
    public static func quickTitle(url: URL, window: Int = 1 << 16) -> String? {
        var fallback: String?
        for line in tailLines(url: url, window: window).reversed() {
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

    /// Context size as of the newest assistant turn in the tail window —
    /// the window is larger than the title's because a session can end on
    /// a bulky tool result. Nil when no turn is in reach.
    public static func quickUsage(url: URL, window: Int = 1 << 18) -> ContextUsage? {
        for line in tailLines(url: url, window: window).reversed() {
            guard let entry = try? TranscriptEntry(line: Data(line), index: 0),
                entry.kind == .assistant, !entry.isSidechain,
                let usage = entry.usage,
                let at = entry.timestamp
            else { continue }
            guard let context = contextTokens(of: usage) else { continue }
            // The usage names which TTL the cache write bought; entries
            // predating the breakdown default to the short clock.
            let oneHour =
                usage["cache_creation"]?["ephemeral_1h_input_tokens"]?.intValue ?? 0
            return ContextUsage(
                contextTokens: Int64(context),
                at: at,
                cacheTTL: oneHour > 0 ? 3600 : 300)
        }
        return nil
    }

    /// What a cache-cold resume would reprocess: the prompt as the API
    /// last saw it. Summed without trapping — these are three numbers
    /// read out of a file the app does not control, and `+` on Int
    /// aborts the process on overflow.
    private static func contextTokens(of usage: JSONValue) -> Int64? {
        var total: Int64 = 0
        for key in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
            guard let value = usage[key]?.intValue else { continue }
            guard value >= 0 else { return nil }
            let (sum, overflowed) = total.addingReportingOverflow(Int64(value))
            guard !overflowed else { return nil }
            total = sum
        }
        return total > 0 ? total : nil
    }

    /// The complete lines within the last `window` bytes of the file.
    private static func tailLines(url: URL, window: Int) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }

        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd()
        else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n"))
        if start > 0, !lines.isEmpty {
            lines.removeFirst()  // partial line cut by the window
        }
        return lines
    }
}
