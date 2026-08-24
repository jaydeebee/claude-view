import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct WorkflowRunIndexTests {
    /// Builds `<session>/subagents/workflows/wf_test1/` with two agent
    /// metas, a journal, and the persisted script the name comes from.
    private func makeSessionDir() throws -> URL {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfrun-\(UUID().uuidString)")
        let runDir = session.appendingPathComponent("subagents/workflows/wf_test1")
        try FileManager.default.createDirectory(
            at: runDir, withIntermediateDirectories: true)

        for id in ["aaa1", "bbb2"] {
            try Data(#"{"agentType":"workflow-subagent","spawnDepth":1}"#.utf8)
                .write(to: runDir.appendingPathComponent("agent-\(id).meta.json"))
            try Data("{}\n".utf8)
                .write(to: runDir.appendingPathComponent("agent-\(id).jsonl"))
        }
        try Data(
            """
            {"type":"started","key":"v2:k1","agentId":"bbb2"}
            {"type":"result","key":"v2:k1","agentId":"bbb2","result":"{}"}
            {"type":"started","key":"v2:k2","agentId":"aaa1"}
            not json
            """.utf8
        ).write(to: runDir.appendingPathComponent("journal.jsonl"))

        let scripts = session.appendingPathComponent("workflows/scripts")
        try FileManager.default.createDirectory(
            at: scripts, withIntermediateDirectories: true)
        try Data("// script".utf8)
            .write(to: scripts.appendingPathComponent("nightly-review-wf_test1.js"))
        return session
    }

    @Test func runLoadsAgentsInStartOrderWithJournalTruth() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }

        let runs = WorkflowRunIndex.load(
            subagentsDir: session.appendingPathComponent("subagents"))
        let run = try #require(runs.first)
        #expect(runs.count == 1)
        #expect(run.runId == "wf_test1")
        #expect(run.name == "nightly-review")
        // bbb2 started first, so it leads despite sorting after aaa1.
        #expect(run.agents.map(\.agentId) == ["bbb2", "aaa1"])
        #expect(run.finished == ["bbb2"])
    }

    @Test func metaWithoutJournalEntryStillLists() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }
        let runDir = session.appendingPathComponent("subagents/workflows/wf_test1")
        try Data(#"{"agentType":"workflow-subagent","spawnDepth":1}"#.utf8)
            .write(to: runDir.appendingPathComponent("agent-ccc3.meta.json"))

        let run = try #require(
            WorkflowRunIndex.load(
                subagentsDir: session.appendingPathComponent("subagents")
            ).first)
        // Journal-unseen agents trail the started ones.
        #expect(run.agents.map(\.agentId) == ["bbb2", "aaa1", "ccc3"])
        #expect(!run.finished.contains("ccc3"))
    }

    @Test func missingWorkflowsDirMeansNoRuns() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("wfrun-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(WorkflowRunIndex.load(subagentsDir: empty).isEmpty)
    }
}
