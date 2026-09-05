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

    /// Whether that presumption holds as of `now`.
    ///
    /// A turn cannot have happened later than now, so a turn dated in the
    /// future is a clock disagreeing — a transcript written on another
    /// machine, a system clock nudged, a timezone confusion in the
    /// harness. Taken at face value it made a row warm until that future
    /// arrived, which for a badly wrong clock is forever: the sidebar
    /// would show a session as cached that had gone cold days ago. A
    /// minute of slack absorbs ordinary skew; past that, no claim.
    public func isWarm(now: Date = Date()) -> Bool {
        guard at <= now.addingTimeInterval(60) else { return false }
        return warmUntil > now
    }
}

/// Cheap glances at a transcript without reading the whole file — sidebar
/// rows need a title for sessions that may be tens of megabytes.
public enum TranscriptPeek {
    /// What the sidebar wants to know about a transcript it has not
    /// opened: what to call it, and how much context it is carrying.
    public struct Summary: Sendable {
        /// Newest `ai-title` in the window, or the newest `last-prompt`
        /// when the session never earned one.
        public let title: String?
        /// Context size as of the newest assistant turn in the window,
        /// with the cache clock that turn's writes bought.
        public let usage: ContextUsage?

        public init(title: String?, usage: ContextUsage?) {
            self.title = title
            self.usage = usage
        }
    }

    /// Both facts from one read of the tail.
    ///
    /// They were two calls with two windows, which meant opening each
    /// transcript twice and reading the same region of it twice — for
    /// every row of every project in the history list, on the scan that
    /// has to finish before the sidebar can draw anything. The larger
    /// window subsumes the smaller, so one read answers both, and a title
    /// sitting between the old windows is now found rather than missed.
    public static func quickSummary(url: URL, window: Int = 1 << 18) -> Summary {
        var title: String?
        var fallbackTitle: String?
        var newest: (context: Int64, at: Date)?
        var ttl: TimeInterval?
        // The TTL search walks back past the newest turn looking for one
        // that actually wrote cache. Bounded, because a session that only
        // ever reads cache has no such turn anywhere, and unbounded the
        // search then parses every line of a window that can be 4MB — for
        // every row of every project, in the scan the first paint waits on.
        var turnsSinceNewest = 0
        var ttlSettled = false

        for line in tailLines(url: url, window: window).reversed() {
            guard let entry = try? TranscriptEntry(line: Data(line), index: 0) else {
                continue
            }
            if title == nil, let found = entry.aiTitle {
                title = found
            }
            if fallbackTitle == nil, let prompt = entry.lastPrompt {
                fallbackTitle = String(prompt.prefix(80))
            }
            if entry.kind == .assistant, !entry.isSidechain, let usage = entry.usage {
                if newest == nil, let at = entry.timestamp,
                    let context = contextTokens(of: usage)
                {
                    newest = (context, at)
                }
                if !ttlSettled {
                    if let bought = cacheTTL(of: usage) {
                        ttl = bought
                        ttlSettled = true
                    } else if newest != nil {
                        turnsSinceNewest += 1
                        ttlSettled = turnsSinceNewest >= Self.ttlSearchDepth
                    }
                }
            }
            if title != nil, newest != nil, ttlSettled { break }
        }

        return Summary(
            title: title ?? fallbackTitle,
            // No turn in the window wrote cache at all: the short clock is
            // the safe guess, since it only under-promises warmth.
            usage: newest.map {
                ContextUsage(contextTokens: $0.context, at: $0.at, cacheTTL: ttl ?? 300)
            })
    }

    /// The working directory the session ran in, read from the head of
    /// the file.
    ///
    /// Every conversation entry carries `cwd`; the sidecars around them do
    /// not, so this scans forward until one answers. The head, not the
    /// tail, because the answer is settled by the first turn and a small
    /// window is enough — measured across this machine's transcripts, the
    /// first `cwd` always lands within the opening handful of lines.
    ///
    /// Worth reading rather than deriving: the project directory's name is
    /// the cwd with every `/` turned into `-`, which a directory name
    /// containing `-` makes ambiguous in the other direction.
    public static func quickCwd(url: URL, window: Int = 1 << 14) -> String? {
        for line in headLines(url: url, window: window) {
            guard let entry = try? TranscriptEntry(line: Data(line), index: 0),
                let cwd = entry.raw["cwd"]?.stringValue, !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    /// How many turns back to look for one that wrote cache before
    /// settling for the short clock.
    private static let ttlSearchDepth = 20

    /// Which cache a turn's write bought, or nil when it wrote none.
    ///
    /// Read off the newest turn alone this was wrong for every session
    /// that ends on turns with an all-zero breakdown: no 1h number meant
    /// 5m, so an hour-cached session reported as five minutes and the
    /// sidebar called it cold while it was still warm. Only a turn that
    /// actually wrote cache is evidence, so the search walks back until
    /// one does.
    private static func cacheTTL(of usage: JSONValue) -> TimeInterval? {
        guard let creation = usage["cache_creation"] else { return nil }
        if (creation["ephemeral_1h_input_tokens"]?.intValue ?? 0) > 0 { return 3600 }
        if (creation["ephemeral_5m_input_tokens"]?.intValue ?? 0) > 0 { return 300 }
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

    /// The complete lines within the first `window` bytes of the file.
    /// The last line is dropped unless the window reached the end, since
    /// it may have been cut mid-write.
    private static func headLines(url: URL, window: Int) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: window), !data.isEmpty else {
            return []
        }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if data.count == window, !lines.isEmpty {
            lines.removeLast()
        }
        return lines
    }

    /// How far tailLines will widen its window chasing a complete line.
    /// A transcript can end on a multi-megabyte line — an inline base64
    /// image, a giant tool result — and everything useful sits behind it.
    private static let maxTailWindow: UInt64 = 1 << 22

    /// The complete lines within the last `window` bytes of the file.
    ///
    /// Two ways the obvious version comes back empty-handed:
    ///
    /// Dropping the first line is right only when the window opened
    /// mid-line. When it opens exactly on a line start — which for a
    /// fixed window is a matter of luck — the line dropped is complete,
    /// and for a caller reading the tail it is the newest one. So the
    /// read starts a byte early: that byte says which case this is.
    ///
    /// And a line longer than the window leaves nothing complete at all,
    /// so a session that ends on a huge line had no title and no context
    /// count anywhere in the sidebar. The window widens until it finds a
    /// line, reaches the head of the file, or gives up at `maxTailWindow`.
    private static func tailLines(url: URL, window: Int) -> [Data.SubSequence] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }

        var window = UInt64(max(window, 1))
        while true {
            let start = size > window ? size - window : 0
            let readFrom = start > 0 ? start - 1 : 0
            guard (try? handle.seek(toOffset: readFrom)) != nil,
                let data = try? handle.readToEnd()
            else { return [] }

            var lines = data.split(separator: UInt8(ascii: "\n"))
            if start > 0, data.first != UInt8(ascii: "\n"), !lines.isEmpty {
                lines.removeFirst()  // partial line cut by the window
            }
            if !lines.isEmpty || start == 0 || window >= Self.maxTailWindow {
                return lines
            }
            window = min(window * 4, Self.maxTailWindow)
        }
    }
}
