import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct AgentCompletionScannerTests {
    private func makeTempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("completions-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func append(_ s: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(s.utf8))
    }

    private static let notification = """
        {"type":"user","uuid":"u-tn","timestamp":"2026-08-23T10:00:00.000Z","message":{"role":"user","content":"<task-notification>\\n<task-id>fork123</task-id>\\n<status>completed</status>\\n<summary>Agent finished</summary>\\n</task-notification>"}}
        """

    private static let toolResult = """
        {"type":"user","uuid":"u-tr","timestamp":"2026-08-23T10:05:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_777","content":"done"}]}}
        """

    @Test func notificationMarksTheAgentStopped() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Self.notification + "\n", to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byAgentId["fork123"]
            == TranscriptEntry.parseTimestamp("2026-08-23T10:00:00.000Z"))
    }

    @Test func notificationToolUseIdIsRecordedToo() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(
            """
            {"type":"user","uuid":"u-tn2","timestamp":"2026-08-23T11:00:00Z","message":{"role":"user","content":"<task-notification>\\n<task-id>bg9</task-id>\\n<tool-use-id>toolu_bg9</tool-use-id>\\n<status>killed</status>\\n</task-notification>"}}\n
            """, to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byAgentId["bg9"] != nil)
        #expect(events.byToolUseId["toolu_bg9"] != nil)
    }

    @Test func wrappedNotificationInSubagentTranscriptCounts() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(
            """
            {"type":"user","uuid":"u-wrap","timestamp":"2026-08-23T12:00:00Z","message":{"role":"user","content":"[SYSTEM NOTIFICATION - NOT USER INPUT]\\nThis is an automated background-task event.\\n\\n<task-notification>\\n<task-id>child7</task-id>\\n<tool-use-id>toolu_child7</tool-use-id>\\n<status>completed</status>\\n</task-notification>"}}\n
            """, to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byAgentId["child7"] != nil)
        #expect(events.byToolUseId["toolu_child7"] != nil)
    }

    @Test func toolResultAnswersTheTaskCall() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(Self.toolResult + "\n", to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byToolUseId["toolu_777"]
            == TranscriptEntry.parseTimestamp("2026-08-23T10:05:00.000Z"))
        #expect(events.byAgentId.isEmpty)
    }

    @Test func queuedCommandAttachmentCompletesTheFork() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(
            """
            {"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-id>fork456</task-id> finished"}}\n
            """, to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byAgentId["fork456"] != nil)
    }

    @Test func eventsAccumulateAcrossPolls() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = AgentCompletionScanner()

        try append(Self.notification + "\n", to: url)
        #expect(scanner.poll(url).byAgentId.count == 1)

        try append(Self.toolResult + "\n", to: url)
        let events = scanner.poll(url)
        #expect(events.byAgentId.count == 1)
        #expect(events.byToolUseId.count == 1)

        // current() answers from memory without re-reading the file.
        try? FileManager.default.removeItem(at: url)
        #expect(scanner.current(url).byAgentId.count == 1)
    }

    @Test func truncationDropsAccumulatedEvents() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let scanner = AgentCompletionScanner()

        try append(Self.notification + "\n", to: url)
        #expect(scanner.poll(url).byAgentId.count == 1)

        // Replaced with a shorter file: the old session's events are gone.
        try Data("{\"fresh\":1}\n".utf8).write(to: url)
        #expect(scanner.poll(url).byAgentId.isEmpty)
    }

    @Test func unrelatedAndMalformedLinesAreIgnored() throws {
        let url = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try append(
            """
            {"type":"assistant","uuid":"a-1","message":{"role":"assistant","content":[{"type":"text","text":"mentions tool_use_id and task-id in prose"}]}}
            not json at all, but with task-id inside
            {"type":"user","uuid":"u-plain","message":{"role":"user","content":"just a prompt"}}\n
            """, to: url)

        let events = AgentCompletionScanner().poll(url)
        #expect(events.byAgentId.isEmpty)
        #expect(events.byToolUseId.isEmpty)
    }
}
