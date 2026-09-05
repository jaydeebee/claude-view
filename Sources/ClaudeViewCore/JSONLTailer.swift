import Foundation

/// Incremental reader for an append-only JSONL file.
///
/// Each `poll()` returns the complete lines written since the last poll.
/// A trailing line without a newline is held back until it completes —
/// Claude Code can be mid-write when we read. Transcripts reach tens of
/// megabytes with multi-megabyte lines (inline base64 images), so reads
/// are chunked and the file is never loaded wholesale.
public final class JSONLTailer {
    public let url: URL
    private var offset: UInt64 = 0
    private var partial = Data()

    /// True when the last `poll()` found the file shrunk and restarted from
    /// the top — accumulated state from earlier polls is now invalid.
    public private(set) var didResetOnLastPoll = false

    private static let chunkSize = 1 << 20

    public init(url: URL) {
        self.url = url
    }

    /// Complete lines appended since the last poll, one at a time, empty
    /// lines skipped.
    ///
    /// Streaming rather than returning them: the first poll of a 30MB
    /// transcript passes 30MB through this method, and a caller that only
    /// screens each line — the completion scanner does exactly that —
    /// should not be handed the file to hold. Callers that keep something
    /// keep their own thing.
    ///
    /// `onReset` fires, before any line, when the file has shrunk
    /// (rotation, replacement, a forked session's file swap) and reading
    /// restarts from the top: whatever the caller accumulated from earlier
    /// polls describes a file that no longer exists.
    ///
    /// A read that fails part way through ends the poll where it stands.
    /// Lines already delivered stay delivered and the offset covers
    /// exactly the chunks consumed, so the next poll resumes on the first
    /// byte this one did not read. Throwing instead — which is what this
    /// did — stranded every line of a successful chunk behind an offset
    /// that had already moved past them.
    public func poll(onReset: () -> Void = {}, onLine: (Data) -> Void) throws {
        didResetOnLastPoll = false
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Vanished or unreadable; keep state, the file may reappear.
            return
        }
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        if size < offset {
            offset = 0
            partial.removeAll()
            didResetOnLastPoll = true
            onReset()
        }
        guard size > offset else { return }

        try handle.seek(toOffset: offset)
        while true {
            guard let chunk = try? handle.read(upToCount: Self.chunkSize),
                !chunk.isEmpty
            else { break }
            offset += UInt64(chunk.count)
            var start = chunk.startIndex
            while let nl = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                partial.append(chunk[start..<nl])
                if !partial.isEmpty {
                    onLine(partial)
                }
                partial = Data()
                start = chunk.index(after: nl)
            }
            partial.append(chunk[start...])
        }
    }

    /// The same lines, collected. Convenient where the caller wants them
    /// all anyway and for tests; on a transcript, prefer the streaming
    /// form and keep only what you need.
    public func poll() throws -> [Data] {
        var lines: [Data] = []
        try poll(onLine: { lines.append($0) })
        return lines
    }
}
