import Foundation
import Testing

@testable import ClaudeViewCore

@Suite struct ConsoleAndNotificationTests {
    private func entries(_ lines: [String]) throws -> [TranscriptEntry] {
        try lines.enumerated().map { try TranscriptEntry(line: Data($1.utf8), index: $0) }
    }

    // MARK: ANSI stripping

    @Test func ansiEscapesVanishFromDisplayText() {
        #expect(ANSIText.stripped("\u{1B}[2mCompacted \u{1B}[22m") == "Compacted ")
        #expect(ANSIText.stripped("\u{1B}[38;5;208mcolor\u{1B}[0m done") == "color done")
        #expect(ANSIText.stripped("\u{1B}]0;title\u{07}text") == "text")
        #expect(ANSIText.stripped("\u{1B}]8;;url\u{1B}\\link") == "link")
        #expect(ANSIText.stripped("\u{1B}creset") == "reset")
        // ESC ( B is the first half of terminfo's sgr0 on this machine, so
        // any `!` command that resets its attributes ends with one of
        // these. Dropping a single scalar left the "B" in the row.
        #expect(ANSIText.stripped("\u{1B}(B\u{1B}[mdone") == "done")
        #expect(ANSIText.stripped("\u{1B})0\u{1B}#8x") == "x")
        // DCS/SOS/PM/APC run to a string terminator, not two characters.
        #expect(ANSIText.stripped("\u{1B}P1;2|payload\u{1B}\\after") == "after")
        #expect(ANSIText.stripped("\u{1B}_status\u{07}after") == "after")
        // A truncated escape at the end consumes what is there and stops.
        #expect(ANSIText.stripped("text\u{1B}(") == "text")
        #expect(ANSIText.stripped("no escapes here") == "no escapes here")
        #expect(ANSIText.stripped("trailing\u{1B}") == "trailing")
    }

    // MARK: `!` console exchanges

    private let bashInputLine = """
        {"type":"user","uuid":"u-in","message":{"role":"user","content":"<bash-input>ls docs</bash-input>"}}
        """
    private let bashOutputLine = """
        {"type":"user","uuid":"u-out","message":{"role":"user","content":"<bash-stdout>SPEC.md</bash-stdout><bash-stderr></bash-stderr>"}}
        """

    @Test func bangCommandPairsWithItsOutput() throws {
        let snapshot = SessionAssembler()
            .assemble(entries: try entries([bashInputLine, bashOutputLine]))
        #expect(snapshot.rows.count == 1)
        guard case .console(let data) = snapshot.rows.first else {
            Issue.record("expected a console row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(data.command == "ls docs")
        #expect(data.stdout == "SPEC.md")
        #expect(data.stderr == nil)  // empty envelope collapses away
        #expect(!data.isPending)
    }

    @Test func bangCommandWithoutOutputYetIsPending() throws {
        let snapshot = SessionAssembler().assemble(entries: try entries([bashInputLine]))
        guard case .console(let data) = snapshot.rows.first else {
            Issue.record("expected a console row")
            return
        }
        #expect(data.isPending)
    }

    @Test func orphanOutputStandsAlone() throws {
        let snapshot = SessionAssembler().assemble(entries: try entries([bashOutputLine]))
        guard case .console(let data) = snapshot.rows.first else {
            Issue.record("expected a console row")
            return
        }
        #expect(data.command == nil)
        #expect(data.stdout == "SPEC.md")
        #expect(!data.isPending)
    }

    @Test func consoleRowsDoNotBecomeTurnPromptsOrTitles() throws {
        let snapshot = SessionAssembler()
            .assemble(entries: try entries([bashInputLine, bashOutputLine]))
        #expect(snapshot.title == nil)
    }

    // MARK: slash-command output

    @Test func slashCommandOutputLosesItsAnsi() throws {
        let line = """
            {"type":"user","uuid":"u-lc","message":{"role":"user","content":"<local-command-stdout>\\u001b[2mCompacted \\u001b[22m</local-command-stdout>"}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([line]))
        guard case .console(let data) = snapshot.rows.first else {
            Issue.record("expected a console row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(data.command == nil)
        #expect(data.stdout == "Compacted")
        #expect(!data.isPending)
    }

    // MARK: task notifications

    /// Mirrors a real completion notice (v2.1.221), scrubbed and shortened.
    private let notificationLine = """
        {"type":"user","uuid":"u-tn","message":{"role":"user","content":"<task-notification>\\n<task-id>fork123</task-id>\\n<output-file>/tmp/tasks/fork123.output</output-file>\\n<status>completed</status>\\n<summary>Agent \\"/code-review\\" finished</summary>\\n<note>A task-notification fires each time this agent stops.</note>\\n<result>All findings verified.</result>\\n<usage><subagent_tokens>75210</subagent_tokens><tool_uses>24</tool_uses><duration_ms>424413</duration_ms></usage>\\n</task-notification>"}}
        """

    @Test func taskNotificationBecomesACard() throws {
        let snapshot = SessionAssembler().assemble(entries: try entries([notificationLine]))
        guard case .taskNotification(let note) = snapshot.rows.first else {
            Issue.record("expected a taskNotification row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(note.taskId == "fork123")
        #expect(note.status == "completed")
        #expect(note.summary == "Agent \"/code-review\" finished")
        #expect(note.result == "All findings verified.")
        #expect(note.durationMs == 424413)
        #expect(note.subagentTokens == 75210)
        #expect(note.toolUses == 24)
    }

    @Test func unshowableDurationsAreDropped() throws {
        for value in ["inf", "-inf", "nan", "1e400", "-1", "0x1p2000"] {
            let line = """
                {"type":"user","uuid":"u-d","message":{"role":"user","content":"<task-notification>\\n<task-id>t1</task-id>\\n<duration_ms>\(value)</duration_ms>\\n</task-notification>"}}
                """
            let snapshot = SessionAssembler().assemble(entries: try entries([line]))
            guard case .taskNotification(let note) = snapshot.rows.first else {
                Issue.record("expected a taskNotification row for \(value)")
                return
            }
            // Admitting these means a trapping Int() conversion downstream.
            #expect(note.durationMs == nil, "\(value) should not be displayable")
        }

        let good = """
            {"type":"user","uuid":"u-ok","message":{"role":"user","content":"<task-notification>\\n<task-id>t2</task-id>\\n<duration_ms>1500</duration_ms>\\n</task-notification>"}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([good]))
        guard case .taskNotification(let note) = snapshot.rows.first else {
            Issue.record("expected a taskNotification row")
            return
        }
        #expect(note.durationMs == 1500)
    }

    @Test func wrappedNotificationInSubagentTranscriptIsStillANotification() throws {
        // How a subagent transcript carries it: isMeta, and the block sits
        // behind the harness preamble instead of leading the entry.
        let wrapped = """
            {"type":"user","uuid":"u-wrapped","isMeta":true,"message":{"role":"user","content":"[SYSTEM NOTIFICATION - NOT USER INPUT]\\nThis is an automated background-task event.\\n\\n<task-notification>\\n<task-id>child7</task-id>\\n<tool-use-id>toolu_child7</tool-use-id>\\n<status>completed</status>\\n<summary>Agent \\"Explore\\" finished</summary>\\n</task-notification>"}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([wrapped]))
        guard case .taskNotification(let note) = snapshot.rows.first else {
            Issue.record("expected a taskNotification row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(note.taskId == "child7")
        #expect(note.status == "completed")
        #expect(note.summary == "Agent \"Explore\" finished")
    }

    @Test func aPromptThatQuotesANotificationStaysAPrompt() throws {
        // Agent prompts quote the tag when describing the format; five such
        // entries exist in this machine's transcripts. They are prompts.
        let quoting = """
            {"type":"user","uuid":"u-quote","message":{"role":"user","content":"Here is what the harness writes:\\n<task-notification>\\n<task-id>t9</task-id>\\n</task-notification>\\nExplain it."}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([quoting]))
        guard case .prompt(_, let text) = snapshot.rows.first else {
            Issue.record("expected a prompt row, got \(String(describing: snapshot.rows.first))")
            return
        }
        #expect(text.contains("Explain it."))
    }

    @Test func userTaskNotificationCompletesItsFork() throws {
        let launchLine = """
            {"type":"system","subtype":"local_command","isMeta":false,"level":"info","uuid":"sys-1","content":"<local-command-stdout>Running in the background as @code-review</local-command-stdout>\\n<forked-skill-launch>{\\"agentId\\":\\"fork123\\",\\"skillName\\":\\"code-review\\",\\"description\\":\\"/code-review\\"}</forked-skill-launch>"}
            """
        let snapshot = SessionAssembler()
            .assemble(entries: try entries([launchLine, notificationLine]))
        guard case .forkLaunch(let fork) = snapshot.rows.first else {
            Issue.record("expected a forkLaunch row")
            return
        }
        #expect(fork.isComplete)
    }

    @Test func taskNotificationResolvesItsSubagent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(
            #"{"agentType":"general-purpose","description":"/code-review","name":"code-review"}"#
                .utf8
        ).write(to: dir.appendingPathComponent("agent-fork123.meta.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("agent-fork123.jsonl"))

        let snapshot = SessionAssembler(subagents: SubagentIndex.load(dir: dir))
            .assemble(entries: try entries([notificationLine]))
        guard case .taskNotification(let note) = snapshot.rows.first else {
            Issue.record("expected a taskNotification row")
            return
        }
        #expect(note.subagent?.name == "code-review")
    }

    /// Meta-flagged user entries (injected context) keep their info-row
    /// treatment even when their text looks like command markup.
    @Test func metaEntriesKeepTheirInfoRows() throws {
        let line = """
            {"type":"user","isMeta":true,"uuid":"u-meta","message":{"role":"user","content":"<local-command-stdout>not a console row</local-command-stdout>"}}
            """
        let snapshot = SessionAssembler().assemble(entries: try entries([line]))
        guard case .info = snapshot.rows.first else {
            Issue.record("expected an info row, got \(String(describing: snapshot.rows.first))")
            return
        }
    }
}
