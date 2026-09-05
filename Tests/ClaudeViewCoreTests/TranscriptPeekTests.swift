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
        #expect(TranscriptPeek.quickUsage(url: missing) == nil)
        #expect(TranscriptPeek.quickUsage(url: empty) == nil)
    }

    @Test func usageComesFromTheNewestAssistantTurn() throws {
        let url = try write([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-23T10:00:00Z","message":{"role":"assistant","usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"old"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-08-23T10:05:00Z","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300,"output_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0}},"content":[{"type":"text","text":"new"}]}}"#,
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"bye"}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = try #require(TranscriptPeek.quickUsage(url: url))
        #expect(usage.contextTokens == 2302)
        #expect(usage.at == TranscriptEntry.parseTimestamp("2026-08-23T10:05:00Z"))
        #expect(usage.cacheTTL == 300)
        #expect(usage.warmUntil == usage.at.addingTimeInterval(300))
    }

    @Test func absurdTokenCountsAreRejectedNotSummed() throws {
        // Int + Int aborts the process on overflow, and these three numbers
        // come out of a file the app does not control. The bad turn must be
        // the newest one, since that is the only turn quickUsage reads.
        let overflowing = try write([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-23T10:00:00Z","message":{"role":"assistant","usage":{"input_tokens":9223372036854775807,"cache_read_input_tokens":1,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"hi"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: overflowing) }
        #expect(TranscriptPeek.quickUsage(url: overflowing) == nil)

        let negative = try write([
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-08-23T09:00:00Z","message":{"role":"assistant","usage":{"input_tokens":-5,"cache_read_input_tokens":10,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"hi"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: negative) }
        #expect(TranscriptPeek.quickUsage(url: negative) == nil)
    }

    @Test func oneHourCacheWritesBuyTheLongClock() throws {
        let url = try write([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-23T10:00:00Z","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":500,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":40}},"content":[{"type":"text","text":"hi"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try #require(TranscriptPeek.quickUsage(url: url)).cacheTTL == 3600)
    }

    /// The window has to open somewhere, and sometimes it opens exactly on
    /// a line start. Dropping that line as a partial loses the newest thing
    /// the tail had to say.
    @Test func aLineOnTheWindowBoundaryIsNotDropped() throws {
        let title = #"{"type":"ai-title","aiTitle":"Boundary title","sessionId":"s"}"#
        let filler = #"{"type":"user","message":{"role":"user","content":"x"},"uuid":"u"}"#
        let url = try write([filler, title, filler])
        defer { try? FileManager.default.removeItem(at: url) }

        // Exactly the bytes of the last two lines, so the window opens on
        // the first byte of the title.
        let window = (title + "\n" + filler + "\n").utf8.count
        #expect(TranscriptPeek.quickTitle(url: url, window: window) == "Boundary title")
    }

    /// A transcript can end on a line bigger than the whole window — an
    /// inline image, a giant tool result. Everything the tail is read for
    /// sits behind it.
    @Test func aFinalLineLongerThanTheWindowDoesNotHideTheRest() throws {
        let title = #"{"type":"ai-title","aiTitle":"Behind the wall","sessionId":"s"}"#
        let payload = String(repeating: "x", count: 200_000)
        let huge = #"{"type":"user","message":{"role":"user","content":"\#(payload)"},"uuid":"u"}"#
        let url = try write([title, huge])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(TranscriptPeek.quickTitle(url: url, window: 1024) == "Behind the wall")
    }

    /// A turn that wrote no cache says nothing about the TTL. Reading the
    /// newest turn alone, an all-zero breakdown looked like a 5m write and
    /// an hour-cached session reported five minutes of warmth.
    @Test func theLongClockSurvivesTurnsThatWroteNoCache() throws {
        let url = try write([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-23T10:00:00Z","message":{"role":"assistant","usage":{"input_tokens":2,"cache_read_input_tokens":500,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":40}},"content":[{"type":"text","text":"bought an hour"}]}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-08-23T10:30:00Z","message":{"role":"assistant","usage":{"input_tokens":1,"cache_read_input_tokens":900,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}},"content":[{"type":"text","text":"wrote nothing"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = try #require(TranscriptPeek.quickUsage(url: url))
        // Size and clock start come from the newest turn …
        #expect(usage.contextTokens == 901)
        #expect(usage.at == TranscriptEntry.parseTimestamp("2026-08-23T10:30:00Z"))
        // … the TTL from the newest turn that actually bought one.
        #expect(usage.cacheTTL == 3600)
    }

    @Test func sidechainAndEmptyUsageEntriesAreSkipped() throws {
        let url = try write([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-08-23T09:00:00Z","message":{"role":"assistant","usage":{"input_tokens":3,"cache_read_input_tokens":700,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"main"}]}}"#,
            #"{"type":"assistant","uuid":"a2","isSidechain":true,"timestamp":"2026-08-23T10:00:00Z","message":{"role":"assistant","usage":{"input_tokens":9,"cache_read_input_tokens":9999,"cache_creation_input_tokens":0},"content":[{"type":"text","text":"agent"}]}}"#,
            #"{"type":"assistant","uuid":"a3","timestamp":"2026-08-23T11:00:00Z","message":{"role":"assistant","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1},"content":[{"type":"text","text":"synthetic"}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let usage = try #require(TranscriptPeek.quickUsage(url: url))
        #expect(usage.contextTokens == 703)
        #expect(usage.cacheTTL == 300)  // no breakdown → short clock
    }
}
