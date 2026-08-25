import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct FileStampTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The whole reason FileStamp exists. A URL value that has already
    /// answered a resource-value question keeps answering with the same
    /// date; asking by path does not. Both halves matter: if Foundation
    /// ever stops caching, the second expectation fails and the helper's
    /// doc comment — and the two bugs it cites — need revisiting.
    @Test func aReusedURLGoesStaleWhereFileStampDoesNot() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("journal.jsonl")
        try Data("one\n".utf8).write(to: file)

        // Fetching through the URL first is what latches the value.
        let throughURL = (try? file.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let before = FileStamp.modified(file)

        var seenByURL = Set<Date>()
        var seenByPath = Set<Date>()
        for n in 2...5 {
            Thread.sleep(forTimeInterval: 0.02)
            try Data("line \(n)\n".utf8).write(to: file)
            if let date = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            {
                seenByURL.insert(date)
            }
            seenByPath.insert(FileStamp.modified(file))
        }

        #expect(throughURL != nil)
        #expect(seenByURL.count == 1, "a reused URL is expected to memoize its answer")
        #expect(seenByPath.count == 4, "by path, every write should be visible")
        #expect(FileStamp.modified(file) > before)
    }

    /// A file that cannot be statted has not changed, so callers keying a
    /// cache on this never invalidate on a missing file.
    @Test func anAbsentFileStampsAsDistantPast() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nothing-here.jsonl")

        #expect(FileStamp.modified(missing) == .distantPast)
        #expect(FileStamp.of(missing).modified == nil)
        #expect(FileStamp.of(missing).created == nil)
    }

    /// A directory's own timestamp moves when an entry is added to it but
    /// not when an existing file inside it is appended to — the asymmetry
    /// the subagent-index caches are built on.
    @Test func directoryStampsMoveOnAdditionNotOnAppend() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-a1.jsonl")
        try Data("{}\n".utf8).write(to: file)

        let afterCreate = FileStamp.modified(dir)
        Thread.sleep(forTimeInterval: 0.02)
        try Data("{}\n{}\n".utf8).write(to: file)
        let afterAppend = FileStamp.modified(dir)
        Thread.sleep(forTimeInterval: 0.02)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("agent-a2.jsonl"))
        let afterSecondFile = FileStamp.modified(dir)

        #expect(afterAppend == afterCreate)
        #expect(afterSecondFile > afterCreate)
    }
}
