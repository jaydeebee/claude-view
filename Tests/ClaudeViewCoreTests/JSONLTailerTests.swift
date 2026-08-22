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
}
