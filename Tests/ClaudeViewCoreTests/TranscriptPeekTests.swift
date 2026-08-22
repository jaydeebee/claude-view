import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct TranscriptPeekTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peek-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    @Test func prefersLatestAiTitle() throws {
        let url = try write([
            #"{"type":"ai-title","aiTitle":"Old title","sessionId":"s"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1"}"#,
            #"{"type":"ai-title","aiTitle":"New title","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"latest prompt","leafUuid":"x","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptPeek.quickTitle(url: url) == "New title")
    }

    @Test func fallsBackToLastPrompt() throws {
        let url = try write([
            #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u1"}"#,
            #"{"type":"last-prompt","lastPrompt":"the latest prompt","leafUuid":"x","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptPeek.quickTitle(url: url) == "the latest prompt")
    }

    @Test func titleBeyondWindowIsMissedGracefully() throws {
        let padding = String(repeating: "x", count: 200)
        var lines = [#"{"type":"ai-title","aiTitle":"Buried title","sessionId":"s"}"#]
        for i in 0..<100 {
            lines.append(#"{"type":"user","message":{"role":"user","content":"\#(padding)\#(i)"},"uuid":"u\#(i)"}"#)
        }
        let url = try write(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TranscriptPeek.quickTitle(url: url, window: 1024) == nil)
    }

    @Test func emptyAndMissingFiles() throws {
        let missing = URL(filePath: "/nonexistent/nope.jsonl")
        #expect(TranscriptPeek.quickTitle(url: missing) == nil)
        let empty = try write([])
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(TranscriptPeek.quickTitle(url: empty) == nil)
    }
}
