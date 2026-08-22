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

    /// Complete lines appended since the last poll, empty lines skipped.
    ///
    /// If the file shrank (rotation, replacement — e.g. a forked session
    /// file swap), reading restarts from the top.
    public func poll() throws -> [Data] {
        didResetOnLastPoll = false
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Vanished or unreadable; keep state, the file may reappear.
            return []
        }
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        if size < offset {
            offset = 0
            partial.removeAll()
            didResetOnLastPoll = true
        }
        guard size > offset else { return [] }

        try handle.seek(toOffset: offset)
        var lines: [Data] = []
        while true {
            guard let chunk = try handle.read(upToCount: Self.chunkSize),
                !chunk.isEmpty
            else { break }
            offset += UInt64(chunk.count)
            var start = chunk.startIndex
            while let nl = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) {
                partial.append(chunk[start..<nl])
                if !partial.isEmpty {
                    lines.append(partial)
                }
                partial = Data()
                start = chunk.index(after: nl)
            }
            partial.append(chunk[start...])
        }
        return lines
    }
}
