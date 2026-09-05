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

        #expect(snapshot.rows.count == 5)
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
        guard case .bookkeeping = snapshot.rows[4] else {
            Issue.record("row 4 should be the ai-title bookkeeping stamp")
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

    /// Sidecars feed the header AND stay behind as bookkeeping rows —
    /// hidden by default, shown by the internals switch. Nothing the
    /// file holds is lost at assembly time.
    @Test func sidecarsFoldIntoHeaderAndRemainAsBookkeeping() throws {
        let lines = [
            Fixtures.aiTitle,
            #"{"type":"mode","mode":"normal","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"do the thing","leafUuid":"x","sessionId":"s"}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"queued","sessionId":"s","timestamp":"2026-08-22T15:00:00Z"}"#,
        ]
        let snapshot = SessionAssembler().assemble(entries: try entries(lines))
        #expect(snapshot.rows.count == lines.count)
        for row in snapshot.rows {
            guard case .bookkeeping = row else {
                Issue.record("expected only bookkeeping rows, got \(row)")
                return
            }
        }
        #expect(snapshot.title == "Fix foo.swift loop bounds")
        #expect(snapshot.mode == "normal")
        #expect(snapshot.permissionMode == "acceptEdits")
        #expect(snapshot.lastPrompt == "do the thing")
    }

    /// Conversation entries always carry a uuid; sidecars never do. An
    /// unknown type without one (atis-latch, or whatever ships next) is
    /// bookkeeping; an unknown type WITH one is conversation content and
    /// keeps its loud unrecognized-entry row.
    @Test func unknownSidecarsAreBookkeepingUnknownContentIsNot() throws {
        let lines = [
            #"{"type":"atis-latch","atis":"","sessionId":"s"}"#,
            Fixtures.mysteryEntry,
        ]
        let snapshot = SessionAssembler().assemble(entries: try entries(lines))
        #expect(snapshot.rows.count == 2)
        guard case .bookkeeping(let sidecar) = snapshot.rows[0] else {
            Issue.record("uuid-less unknown should be bookkeeping")
            return
        }
        #expect(sidecar.raw["type"]?.stringValue == "atis-latch")
        guard case .unknown = snapshot.rows[1] else {
            Issue.record("unknown entry with a uuid should stay unknown")
            return
        }
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
        #expect(label == SessionRow.orphanToolResultLabel)
    }

    /// The journal's lines carry no uuid, so the transcript rules call them
    /// session state and the run's pane comes up empty. Read as a journal
    /// they are rows with titles.
    @Test func journalLinesBecomeRowsInsteadOfHiddenSidecars() throws {
        let journal = [
            #"{"type":"started","key":"v2:abc","agentId":"a7bb6ac514f3155f5"}"#,
            #"{"type":"result","key":"v2:abc","agentId":"a7bb6ac514f3155f5","result":{"findings":[]}}"#,
        ]

        let asTranscript = SessionAssembler().assemble(entries: try entries(journal))
        for row in asTranscript.rows {
            guard case .bookkeeping = row else {
                Issue.record("transcript rules should still hide these")
                return
            }
        }

        let asJournal = SessionAssembler(source: .workflowJournal)
            .assemble(entries: try entries(journal))
        #expect(asJournal.rows.count == 2)
        guard case .info(_, let startLabel) = asJournal.rows[0],
            case .info(_, let resultLabel) = asJournal.rows[1]
        else {
            Issue.record("journal lines should be info rows")
            return
        }
        // No metas loaded, so the agent is named by the head of its id.
        #expect(startLabel == "started · a7bb6ac5")
        #expect(resultLabel == "result · a7bb6ac5")
        #expect(asJournal.rowIds.count == asJournal.rows.count)
        #expect(Set(asJournal.rowIds).count == asJournal.rows.count)
    }

    /// With the run's metas in hand the rows say who, not which id.
    @Test func journalRowsUseAgentNamesWhenMetasAreLoaded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(
            #"{"name":"verify:JSONLTailer","agentType":"claude","description":"check it"}"#.utf8
        ).write(to: dir.appendingPathComponent("agent-a7bb6ac514f3155f5.meta.json"))
        try Data("{}\n".utf8)
            .write(to: dir.appendingPathComponent("agent-a7bb6ac514f3155f5.jsonl"))

        let assembler = SessionAssembler(
            subagents: SubagentIndex.load(dir: dir), source: .workflowJournal)
        let snapshot = assembler.assemble(
            entries: try entries([
                #"{"type":"result","agentId":"a7bb6ac514f3155f5","result":{"ok":true}}"#
            ]))
        guard case .info(_, let label) = snapshot.rows.first else {
            Issue.record("expected an info row")
            return
        }
        #expect(label == "result · verify:JSONLTailer")
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

        let index = SubagentIndex.load(dir: dir)
        #expect(index.byToolUseId.count == 1)

        let assembler = SessionAssembler(subagents: index)
        let snapshot = assembler.assemble(entries: try entries([Fixtures.assistantToolUse]))
        guard case .toolCall(let call) = snapshot.rows.first else {
            Issue.record("expected tool call row")
            return
        }
        #expect(call.subagent?.agentId == "abc123")
        #expect(call.subagent?.agentType == "Explore")
        #expect(call.subagent?.transcriptURL.lastPathComponent == "agent-abc123.jsonl")
        #expect(call.subagent?.stoppedByUser == false)
    }

    @Test func everyRowFromOneEntryGetsItsOwnId() throws {
        // One assistant message, three content blocks — the shape that
        // silently dropped tool calls when identity came from the entry.
        let multiBlock = """
            {"type":"assistant","uuid":"a-multi","message":{"role":"assistant","id":"msg_1","content":[{"type":"text","text":"looking"},{"type":"tool_use","id":"tu-1","name":"Read","input":{}},{"type":"tool_use","id":"tu-2","name":"Read","input":{}}]}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([multiBlock]))

        #expect(snapshot.rows.count == 3)
        #expect(snapshot.rowIds.count == snapshot.rows.count)
        #expect(Set(snapshot.rowIds).count == 3)
        // All three still name the entry they came from.
        #expect(snapshot.rowIds.allSatisfy { $0.hasPrefix("a-multi#") })
    }

    @Test func rowIdsSurviveAppendsUnchanged() throws {
        let first = Fixtures.assistantToolUse
        let second = """
            {"type":"user","uuid":"u-later","message":{"role":"user","content":"next"}}
            """
        let assembler = SessionAssembler()
        let before = assembler.assemble(entries: try entries([first]))
        let after = assembler.assemble(entries: try entries([first, second]))

        // A live session re-assembles on every append; earlier rows must
        // keep their identity or SwiftUI rebuilds them mid-session.
        #expect(Array(after.rowIds.prefix(before.rowIds.count)) == before.rowIds)
    }

    @Test func userKilledAgentCarriesItsStamp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(
            #"{"agentType":"general-purpose","description":"review","name":"code-review","spawnDepth":1,"stoppedByUser":true}"#
                .utf8
        ).write(to: dir.appendingPathComponent("agent-dead1.meta.json"))

        let index = SubagentIndex.load(dir: dir)
        #expect(index.byAgentId["dead1"]?.stoppedByUser == true)
    }

    @Test func totalTokensReminderFeedsTheBudgetGauge() throws {
        let lines = [
            #"{"type":"attachment","uuid":"at-t1","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>15000000 tokens left</total_tokens>"}}"#,
            #"{"type":"attachment","uuid":"at-t2","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>14945309 tokens left</total_tokens>"}}"#,
        ]
        let snapshot = SessionAssembler().assemble(entries: try entries(lines))
        #expect(snapshot.tokensLeft == 14_945_309)  // last wins
        #expect(snapshot.rows.count == 2)  // the rows themselves remain
    }

    @Test func titleFallsBackToFirstPrompt() throws {
        let snapshot = SessionAssembler().assemble(
            entries: try entries([Fixtures.userPrompt]))
        #expect(snapshot.title == "Fix the bug in foo.swift")
    }
}
