import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct SessionAssemblerTests {
    private func entries(_ lines: [String]) throws -> [TranscriptEntry] {
        try lines.enumerated().map { try TranscriptEntry(line: Data($1.utf8), index: $0) }
    }

    private var conversation: [String] {
        [
            Fixtures.userPrompt,
            Fixtures.assistantThinking,
            Fixtures.assistantToolUse,
            Fixtures.userToolResult,
            Fixtures.assistantText,
            Fixtures.aiTitle,
        ]
    }

    @Test func pairsToolResultIntoItsCallRow() throws {
        let snapshot = SessionAssembler().assemble(entries: try entries(conversation))

        #expect(snapshot.rows.count == 4)
        guard case .prompt(_, let prompt) = snapshot.rows[0] else {
            Issue.record("row 0 should be the prompt")
            return
        }
        #expect(prompt == "Fix the bug in foo.swift")
        guard case .thinking = snapshot.rows[1] else {
            Issue.record("row 1 should be thinking")
            return
        }
        guard case .toolCall(let call) = snapshot.rows[2] else {
            Issue.record("row 2 should be the tool call")
            return
        }
        #expect(call.name == "Read")
        #expect(!call.isPending)
        #expect(!call.resultIsError)
        #expect(
            ContentBlock.flattenedText(of: call.resultContent ?? .null).contains("func foo"))
        guard case .assistantText = snapshot.rows[3] else {
            Issue.record("row 3 should be assistant text")
            return
        }
    }

    @Test func callIsPendingUntilResultArrives() throws {
        let partial = Array(conversation.prefix(3))  // prompt, thinking, tool_use
        let snapshot = SessionAssembler().assemble(entries: try entries(partial))
        guard case .toolCall(let call) = snapshot.rows.last else {
            Issue.record("expected trailing tool call")
            return
        }
        #expect(call.isPending)
    }

    @Test func resultsAttachOutOfOrder() throws {
        let callA = """
            {"type":"assistant","uuid":"a-10","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"tu-A","name":"Read","input":{}}]}}
            """
        let callB = """
            {"type":"assistant","uuid":"a-11","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"tu-B","name":"Bash","input":{}}]}}
            """
        let resultB = """
            {"type":"user","uuid":"u-10","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-B","content":"b done"}]}}
            """
        let resultA = """
            {"type":"user","uuid":"u-11","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-A","content":"a done","is_error":true}]}}
            """
        let snapshot = SessionAssembler().assemble(
            entries: try entries([callA, callB, resultB, resultA]))

        #expect(snapshot.rows.count == 2)
        guard case .toolCall(let a) = snapshot.rows[0],
            case .toolCall(let b) = snapshot.rows[1]
        else {
            Issue.record("expected two tool call rows")
            return
        }
        #expect(a.resultContent?.stringValue == "a done")
        #expect(a.resultIsError)
        #expect(b.resultContent?.stringValue == "b done")
    }

    @Test func sidecarsBecomeHeaderStateNotRows() throws {
        let lines = [
            Fixtures.aiTitle,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"do the thing","leafUuid":"x","sessionId":"s"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"queued","sessionId":"s","timestamp":"2026-08-22T15:00:00Z"}"#,
        ]
        let snapshot = SessionAssembler().assemble(entries: try entries(lines))
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.title == "Fix foo.swift loop bounds")
        #expect(snapshot.mode == "normal")
        #expect(snapshot.permissionMode == "acceptEdits")
        #expect(snapshot.lastPrompt == "do the thing")
    }

    @Test func metaAndSystemAndUnknownBecomeInfoRows() throws {
        let lines = [
            #"{"type":"user","isMeta":true,"uuid":"u-20","message":{"role":"user","content":"harness context"}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1200,"uuid":"s-1"}"#,
            #"{"type":"attachment","uuid":"at-1","attachment":{"type":"task_reminder"}}"#,
            Fixtures.mysteryEntry,
        ]
        let snapshot = SessionAssembler().assemble(entries: try entries(lines))
        #expect(snapshot.rows.count == 4)
        guard case .info(_, let metaLabel) = snapshot.rows[0] else {
            Issue.record("meta user entry should be an info row")
            return
        }
        #expect(metaLabel == "injected context")
        guard case .info(_, let sysLabel) = snapshot.rows[1] else {
            Issue.record("system entry should be an info row")
            return
        }
        #expect(sysLabel == "turn_duration")
        guard case .info(_, let attLabel) = snapshot.rows[2] else {
            Issue.record("attachment entry should be an info row")
            return
        }
        #expect(attLabel == "task_reminder")
        guard case .unknown = snapshot.rows[3] else {
            Issue.record("mystery entry should be an unknown row")
            return
        }
    }

    @Test func orphanResultSurfacesInsteadOfDisappearing() throws {
        let orphan = """
            {"type":"user","uuid":"u-30","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-nope","content":"lost"}]}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([orphan]))
        guard case .info(_, let label) = snapshot.rows.first else {
            Issue.record("expected info row for orphan result")
            return
        }
        #expect(label == "orphan tool result")
    }

    @Test func subagentJoinsItsSpawningCall() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(
            #"{"agentType":"Explore","description":"scan the code","toolUseId":"toolu_777","spawnDepth":1}"#
                .utf8
        ).write(to: dir.appendingPathComponent("agent-abc123.meta.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("agent-abc123.jsonl"))

        let index = SubagentRef.index(dir: dir)
        #expect(index.count == 1)

        let assembler = SessionAssembler(subagents: index)
        let snapshot = assembler.assemble(entries: try entries([Fixtures.assistantToolUse]))
        guard case .toolCall(let call) = snapshot.rows.first else {
            Issue.record("expected tool call row")
            return
        }
        #expect(call.subagent?.agentId == "abc123")
        #expect(call.subagent?.agentType == "Explore")
        #expect(call.subagent?.transcriptURL.lastPathComponent == "agent-abc123.jsonl")
    }

    @Test func titleFallsBackToFirstPrompt() throws {
        let snapshot = SessionAssembler().assemble(
            entries: try entries([Fixtures.userPrompt]))
        #expect(snapshot.title == "Fix the bug in foo.swift")
    }
}
