import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct QuickCwdTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cwd-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    /// Sidecars lead the file and carry no cwd, so the scan has to walk
    /// past them to the first real conversation entry.
    @Test func theCwdIsFoundPastTheOpeningSidecars() throws {
        let url = try write([
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"ai-title","title":"Something"}"#,
            #"{"type":"user","uuid":"u1","cwd":"/Users/jdb/src/etg-nxt","message":{"role":"user","content":"hi"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptPeek.quickCwd(url: url) == "/Users/jdb/src/etg-nxt")
    }

    /// The reason this is read rather than derived: two different real
    /// directories slugify to one project name, so the slug cannot be
    /// turned back into a path.
    @Test func pathsThatShareASlugStayDistinct() throws {
        let dashed = try write([
            #"{"type":"user","uuid":"u1","cwd":"/Users/jdb/src/etg-nxt","message":{"role":"user","content":"hi"}}"#
        ])
        let nested = try write([
            #"{"type":"user","uuid":"u1","cwd":"/Users/jdb/src/etg/nxt","message":{"role":"user","content":"hi"}}"#
        ])
        defer {
            try? FileManager.default.removeItem(at: dashed)
            try? FileManager.default.removeItem(at: nested)
        }
        #expect(
            ClaudePaths.projectSlug(for: "/Users/jdb/src/etg-nxt")
                == ClaudePaths.projectSlug(for: "/Users/jdb/src/etg/nxt"),
            "if these ever stop colliding, reading the cwd is no longer load-bearing")
        #expect(TranscriptPeek.quickCwd(url: dashed) == "/Users/jdb/src/etg-nxt")
        #expect(TranscriptPeek.quickCwd(url: nested) == "/Users/jdb/src/etg/nxt")
    }

    @Test func aFileThatNeverSaysAnswersNil() throws {
        let url = try write([
            #"{"type":"mode","mode":"default"}"#,
            #"not json at all"#,
            #"{"type":"ai-title","title":"Something"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptPeek.quickCwd(url: url) == nil)
    }

    @Test func anEmptyOrMissingFileAnswersNil() throws {
        let empty = try write([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(TranscriptPeek.quickCwd(url: empty) == nil)
        #expect(
            TranscriptPeek.quickCwd(
                url: URL(fileURLWithPath: "/nope/does-not-exist.jsonl")) == nil)
    }

    /// A line cut by the window edge must not be parsed as if complete.
    @Test func aTruncatedTrailingLineIsNotTrusted() throws {
        let url = try write([
            String(repeating: "x", count: 200),
            #"{"type":"user","uuid":"u1","cwd":"/Users/jdb/src/app","message":{"role":"user","content":"hi"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        // A window landing mid-second-line must yield nothing, not a
        // half-parsed entry.
        #expect(TranscriptPeek.quickCwd(url: url, window: 240) == nil)
        #expect(TranscriptPeek.quickCwd(url: url, window: 1 << 14) == "/Users/jdb/src/app")
    }
}
