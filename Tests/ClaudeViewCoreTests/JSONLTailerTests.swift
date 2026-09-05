import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct JSONLTailerTests {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailer-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func append(_ s: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(s.utf8))
    }

    @Test func returnsOnlyCompleteLines() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)

        try append("{\"a\":1}\n{\"b\":2}\n{\"c\":", to: url)
        var lines = try tailer.poll()
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])

        // Nothing new: the partial line stays buffered, not re-emitted.
        #expect(try tailer.poll().isEmpty)

        try append("3}\n", to: url)
        lines = try tailer.poll()
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"c\":3}"])
    }

    @Test func skipsEmptyLines() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)
        try append("{\"a\":1}\n\n\n{\"b\":2}\n", to: url)
        #expect(try tailer.poll().count == 2)
    }

    @Test func lineLargerThanChunkSize() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)

        let big = String(repeating: "x", count: 3 << 20)
        try append("{\"big\":\"\(big)\"}\n{\"after\":true}\n", to: url)
        let lines = try tailer.poll()
        #expect(lines.count == 2)
        #expect(lines[0].count > 3 << 20)
        #expect(String(decoding: lines[1], as: UTF8.self) == "{\"after\":true}")
    }

    @Test func truncationResetsToTop() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)

        try append("{\"a\":1}\n{\"b\":2}\n", to: url)
        #expect(try tailer.poll().count == 2)

        // Replace with a shorter file, as a session fork/rotation would.
        try Data("{\"fresh\":1}\n".utf8).write(to: url)
        #expect(!tailer.didResetOnLastPoll)
        let lines = try tailer.poll()
        #expect(tailer.didResetOnLastPoll)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"fresh\":1}"])
        _ = try tailer.poll()
        #expect(!tailer.didResetOnLastPoll)
    }

    @Test func missingFileIsQuietUntilItAppears() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailer-missing-\(UUID().uuidString).jsonl")
        let tailer = JSONLTailer(url: url)
        #expect(try tailer.poll().isEmpty)

        try Data("{\"born\":1}\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try tailer.poll().count == 1)
    }

    /// The streaming form is what the transcript loader and the completion
    /// scanner use, so it has to agree with the collected one — including
    /// about a file that shrank, which the callers learn about here rather
    /// than after the fact.
    @Test func streamingPollMatchesTheCollectedFormAndAnnouncesAReset() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)

        try append("{\"a\":1}\n{\"b\":2}\n", to: url)
        var streamed: [String] = []
        var resets = 0
        try tailer.poll(onReset: { resets += 1 }) { line in
            streamed.append(String(decoding: line, as: UTF8.self))
        }
        #expect(streamed == ["{\"a\":1}", "{\"b\":2}"])
        #expect(resets == 0)

        // Quiet poll: no lines, no reset.
        streamed.removeAll()
        try tailer.poll(onReset: { resets += 1 }) { streamed.append(String(decoding: $0, as: UTF8.self)) }
        #expect(streamed.isEmpty)
        #expect(resets == 0)

        // Replaced by a shorter file: the reset lands before any line, so a
        // caller can throw away what it accumulated from the old one.
        try Data("{\"z\":9}\n".utf8).write(to: url)
        var linesAfterReset: [String] = []
        var resetCameFirst = false
        try tailer.poll(onReset: { resets += 1; resetCameFirst = linesAfterReset.isEmpty }) {
            linesAfterReset.append(String(decoding: $0, as: UTF8.self))
        }
        #expect(resets == 1)
        #expect(resetCameFirst)
        #expect(linesAfterReset == ["{\"z\":9}"])
        #expect(tailer.didResetOnLastPoll)
    }

    /// A callback that throws — which is how a cancelled loader stops a
    /// 30MB read — must cost nothing but the lines it already took. The
    /// first version of this advanced the offset over the whole chunk and
    /// kept the delivered line in the partial buffer, so the rest of the
    /// chunk was lost and the next poll produced a welded line that parsed
    /// as nothing.
    @Test func aThrowingCallbackLosesNothing() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let tailer = JSONLTailer(url: url)
        struct Stop: Error {}

        try append("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n", to: url)
        var delivered: [String] = []
        #expect(throws: Stop.self) {
            try tailer.poll { line in
                delivered.append(String(decoding: line, as: UTF8.self))
                throw Stop()
            }
        }
        #expect(delivered == ["{\"a\":1}"])

        // Everything the callback never saw is still there, intact and
        // separate, and so is anything appended since.
        try append("{\"d\":4}\n", to: url)
        var rest: [String] = []
        try tailer.poll { rest.append(String(decoding: $0, as: UTF8.self)) }
        #expect(rest == ["{\"b\":2}", "{\"c\":3}", "{\"d\":4}"])
    }
}
