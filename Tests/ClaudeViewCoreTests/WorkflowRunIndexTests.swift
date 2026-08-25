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

    /// aaa1 has a `started` and no result. While the run is live that
    /// means "working"; the journal never says otherwise, so without the
    /// run-state file the agent spins forever — which is what a thrown
    /// agent did before.
    @Test func anUnfinishedAgentLeavesTheRunIncomplete() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }

        let run = try #require(
            WorkflowRunIndex.load(
                subagentsDir: session.appendingPathComponent("subagents")
            ).first)
        #expect(run.finished == ["bbb2"])
        #expect(!run.isComplete)
    }

    /// The launcher writes `<session>/workflows/<runId>.json` when a run
    /// stops. A terminal status there settles the agents the journal left
    /// hanging — an agent that threw gets no result entry, ever.
    @Test func aStoppedRunSettlesAgentsTheJournalNeverAnswersFor() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }
        let state = session.appendingPathComponent("workflows/wf_test1.json")

        for status in ["completed", "failed", "aborted"] {
            try Data(#"{"runId":"wf_test1","status":"\#(status)","agentCount":2}"#.utf8)
                .write(to: state)
            let run = try #require(
                WorkflowRunIndex.load(
                    subagentsDir: session.appendingPathComponent("subagents")
                ).first)
            #expect(run.isComplete, "status \(status) should settle the run")
            // Still unfinished by the journal — the run is what resolves it.
            #expect(run.finished == ["bbb2"])
        }
    }

    /// A run whose state file says it is still going stays open, even
    /// though the file exists — presence alone must not settle anything.
    @Test func aRunningStateFileDoesNotCompleteTheRun() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }
        try Data(#"{"runId":"wf_test1","status":"running","agentCount":2}"#.utf8)
            .write(to: session.appendingPathComponent("workflows/wf_test1.json"))

        let run = try #require(
            WorkflowRunIndex.load(
                subagentsDir: session.appendingPathComponent("subagents")
            ).first)
        #expect(!run.isComplete)
    }

    /// Every agent answered by the journal is enough on its own; the
    /// run-state file is read only when one is unaccounted for.
    @Test func aFullyAnsweredJournalNeedsNoStateFile() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }
        let runDir = session.appendingPathComponent("subagents/workflows/wf_test1")
        try Data(
            """
            {"type":"started","key":"v2:k1","agentId":"bbb2"}
            {"type":"result","key":"v2:k1","agentId":"bbb2","result":"{}"}
            {"type":"started","key":"v2:k2","agentId":"aaa1"}
            {"type":"result","key":"v2:k2","agentId":"aaa1","result":"{}"}
            """.utf8
        ).write(to: runDir.appendingPathComponent("journal.jsonl"))

        let run = try #require(
            WorkflowRunIndex.load(
                subagentsDir: session.appendingPathComponent("subagents")
            ).first)
        #expect(run.isComplete)
        #expect(!FileManager.default.fileExists(
            atPath: session.appendingPathComponent("workflows/wf_test1.json").path))
    }

    /// `runDirectories` is the half a caching caller reads on every scan,
    /// so it must list and order runs without touching a journal.
    @Test func runDirectoriesListsOldestFirstWithoutLoading() throws {
        let session = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: session) }
        let workflows = session.appendingPathComponent("subagents/workflows")
        Thread.sleep(forTimeInterval: 0.02)
        try FileManager.default.createDirectory(
            at: workflows.appendingPathComponent("wf_test2"),
            withIntermediateDirectories: true)
        // Not a run directory, and never mistaken for one.
        try FileManager.default.createDirectory(
            at: workflows.appendingPathComponent("scripts"),
            withIntermediateDirectories: true)

        let dirs = WorkflowRunIndex.runDirectories(
            subagentsDir: session.appendingPathComponent("subagents"))
        #expect(dirs.map(\.lastPathComponent) == ["wf_test1", "wf_test2"])
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
