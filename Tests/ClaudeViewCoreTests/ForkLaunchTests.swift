import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct ForkLaunchTests {
    private func entries(_ lines: [String]) throws -> [TranscriptEntry] {
        try lines.enumerated().map { try TranscriptEntry(line: Data($1.utf8), index: $0) }
    }

    /// Mirrors the real /code-review launch entry (v2.1.221), scrubbed.
    private let launchLine = """
        {"type":"system","subtype":"local_command","isMeta":false,"level":"info","uuid":"sys-1","content":"<local-command-stdout>Running in the background as @code-review</local-command-stdout>\\n<forked-skill-launch>{\\"agentId\\":\\"fork123\\",\\"skillName\\":\\"code-review\\",\\"description\\":\\"/code-review\\"}</forked-skill-launch>"}
        """

    private let notificationLine = """
        {"type":"attachment","uuid":"at-9","attachment":{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\\n<task-id>fork123</task-id>\\n<status>completed</status>\\n</task-notification>"}}
        """

    @Test func forkedSkillLaunchBecomesSubSessionRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(
            #"{"agentType":"general-purpose","description":"/code-review","name":"code-review","spawnDepth":1}"#
                .utf8
        ).write(to: dir.appendingPathComponent("agent-fork123.meta.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("agent-fork123.jsonl"))

        let index = SubagentIndex.load(dir: dir)
        #expect(index.byAgentId["fork123"] != nil)
        #expect(index.byToolUseId.isEmpty)

        let snapshot = SessionAssembler(subagents: index)
            .assemble(entries: try entries([launchLine]))
        guard case .forkLaunch(let fork) = snapshot.rows.first else {
            Issue.record("expected a forkLaunch row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(fork.skillName == "code-review")
        #expect(fork.stdout == "Running in the background as @code-review")
        #expect(fork.isPending)
        #expect(fork.subagent?.name == "code-review")
        #expect(fork.subagent?.transcriptURL.lastPathComponent == "agent-fork123.jsonl")
    }

    @Test func taskNotificationMarksForkComplete() throws {
        let snapshot = SessionAssembler()
            .assemble(entries: try entries([launchLine, notificationLine]))
        guard case .forkLaunch(let fork) = snapshot.rows.first else {
            Issue.record("expected a forkLaunch row")
            return
        }
        #expect(fork.isComplete)
        // The notification itself still shows as a (collapsed) info row.
        #expect(snapshot.rows.count == 2)
    }

    @Test func plainLocalCommandsStayInfoRows() throws {
        let plain = """
            {"type":"system","subtype":"local_command","uuid":"sys-2","content":"<local-command-stdout>Set effort level to xhigh</local-command-stdout>"}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([plain]))
        guard case .info(_, let label) = snapshot.rows.first else {
            Issue.record("expected an info row")
            return
        }
        #expect(label == "local_command")
    }

    @Test func commandEnvelopePromptsRenderClean() throws {
        let envelope = """
            {"type":"user","uuid":"u-1","message":{"role":"user","content":"<command-name>/effort</command-name>\\n<command-message>effort</command-message>\\n<command-args>high</command-args>"}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([envelope]))
        guard case .prompt(_, let text) = snapshot.rows.first else {
            Issue.record("expected a prompt row")
            return
        }
        #expect(text == "/effort high")
    }
}
