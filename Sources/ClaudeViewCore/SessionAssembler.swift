import Foundation

/// A subagent spawned by this session, discovered from
/// `<session>/subagents/agent-<id>.meta.json`.
///
/// Task-spawned agents join to their tool call by `toolUseId`; forked
/// skills (`/code-review` and kin) have no tool call — they join by
/// `agentId` to the `<forked-skill-launch>` marker in the transcript.
public struct SubagentRef: Sendable {
    public let toolUseId: String?
    public let agentId: String
    public let transcriptURL: URL
    public let agentType: String?
    public let name: String?
    public let taskDescription: String?
    /// Set on depth-2+ agents (spawned by another agent, not the session).
    public let parentAgentId: String?
    /// Stamped into the meta when the user kills the agent — the one
    /// stop that may never produce a completion event.
    public let stoppedByUser: Bool
}

/// Every subagent under a session's subagents directory, keyed both ways.
public struct SubagentIndex: Sendable {
    public var byToolUseId: [String: SubagentRef] = [:]
    public var byAgentId: [String: SubagentRef] = [:]

    public init() {}

    public static func load(dir: URL) -> SubagentIndex {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var index = SubagentIndex()
        for metaURL in files where metaURL.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: metaURL),
                let meta = try? JSONValue(data: data)
            else { continue }
            let base = metaURL.lastPathComponent.replacingOccurrences(
                of: ".meta.json", with: "")
            let ref = SubagentRef(
                toolUseId: meta["toolUseId"]?.stringValue,
                agentId: base.replacingOccurrences(of: "agent-", with: ""),
                transcriptURL: dir.appendingPathComponent("\(base).jsonl"),
                agentType: meta["agentType"]?.stringValue,
                name: meta["name"]?.stringValue,
                taskDescription: meta["description"]?.stringValue,
                parentAgentId: meta["parentAgentId"]?.stringValue,
                stoppedByUser: meta["stoppedByUser"]?.boolValue ?? false)
            index.byAgentId[ref.agentId] = ref
            if let toolUseId = ref.toolUseId {
                index.byToolUseId[toolUseId] = ref
            }
        }
        return index
    }
}

/// The XML-ish markers Claude Code embeds in transcript text for local
/// slash commands and forked skill launches.
public enum LocalCommandMarkup {
    /// Text between `<tag>` and `</tag>`, if both are present.
    public static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
            let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// `<command-name>/effort</command-name>...` → "/effort args" — the
    /// prompt the user actually typed, without the envelope.
    public static func commandPrompt(_ text: String) -> String? {
        guard text.hasPrefix("<command-name>"),
            let name = tagContent("command-name", in: text)
        else { return nil }
        let args = tagContent("command-args", in: text) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }
}

/// A tool call and (eventually) its result, paired by tool_use_id.
public struct ToolCallRowData: Sendable {
    public let callEntry: TranscriptEntry
    public let toolUseId: String
    public let name: String
    public let input: JSONValue

    public var resultEntry: TranscriptEntry?
    public var resultContent: JSONValue?
    public var resultIsError: Bool = false
    public var subagent: SubagentRef?

    /// Still running: the result entry hasn't been written yet.
    public var isPending: Bool { resultEntry == nil }
}

/// A forked skill launch (`/code-review` → background agent): a
/// sub-session with no spawning tool call. Completion is signaled later
/// by a task-notification carrying the agent id.
public struct ForkLaunchRowData: Sendable {
    public let entry: TranscriptEntry
    public let agentId: String
    public let skillName: String?
    public let launchDescription: String?
    public let stdout: String?
    public var subagent: SubagentRef?
    public var isComplete = false

    public var isPending: Bool { !isComplete }
}

/// A command run at the local console: a `!` shell command (its input
/// entry paired with the output entry that follows) or a slash command's
/// printed output. Output text arrives ANSI-stripped.
public struct ConsoleRowData: Sendable {
    public let entry: TranscriptEntry
    /// The typed `!` command; nil when the row is output alone.
    public let command: String?
    public var stdout: String?
    public var stderr: String?
    public var outputEntry: TranscriptEntry?

    /// A `!` command whose output entry hasn't been written yet.
    public var isPending: Bool { command != nil && outputEntry == nil }
}

/// A background agent's completion notice, delivered into the parent
/// transcript as a user entry full of XML. Parsed into its parts; the
/// task id doubles as the join key to the agent's own transcript.
public struct TaskNotificationRowData: Sendable {
    public let entry: TranscriptEntry
    public let taskId: String?
    public let status: String?
    public let summary: String?
    public let result: String?
    public let durationMs: Double?
    public let subagentTokens: Int64?
    public let toolUses: Int64?
    public var subagent: SubagentRef?
}

/// One row of the rendered transcript, in file order.
public enum SessionRow: Sendable {
    case prompt(TranscriptEntry, text: String)
    case assistantText(TranscriptEntry, text: String)
    case thinking(TranscriptEntry, text: String)
    case toolCall(ToolCallRowData)
    case forkLaunch(ForkLaunchRowData)
    case console(ConsoleRowData)
    case taskNotification(TaskNotificationRowData)
    case info(TranscriptEntry, label: String)
    /// Session-state sidecars (mode stamps, latches, file-history
    /// checkpoints): folded into header state where they carry any, and
    /// kept as rows so a viewer can choose to see the file's full truth.
    case bookkeeping(TranscriptEntry)
    case unknown(TranscriptEntry)

    /// Label of the info row standing in for a tool result whose call is
    /// missing. Named because display keys off it: a plain string in two
    /// files drifts, and the row disappears again when it does.
    public static let orphanToolResultLabel = "orphan tool result"

    /// Identifies the *entry* this row came from — several rows can share
    /// one. Row identity lives in `SessionSnapshot.rowIds`; deliberately
    /// not `id`, so nothing mistakes this for something unique.
    public var entryKey: String { "\(entry.id)#\(entry.index)" }

    public var entry: TranscriptEntry {
        switch self {
        case .prompt(let e, _), .assistantText(let e, _), .thinking(let e, _),
            .info(let e, _), .bookkeeping(let e), .unknown(let e):
            return e
        case .toolCall(let data):
            return data.callEntry
        case .forkLaunch(let data):
            return data.entry
        case .console(let data):
            return data.entry
        case .taskNotification(let data):
            return data.entry
        }
    }
}

/// Everything the header and transcript view need, derived purely from the
/// entry list (plus the subagent index) — cheap to rebuild on every append.
public struct SessionSnapshot: Sendable {
    public var title: String?
    public var lastPrompt: String?
    public var mode: String?
    public var permissionMode: String?
    /// Latest total_tokens_reminder value — the context budget remaining,
    /// as the harness last reported it to the model.
    public var tokensLeft: Int64?
    public var rows: [SessionRow] = []
    /// Identity for each row in `rows`, parallel and same length. One
    /// entry yields one row per content block, so the entry's own key
    /// repeats; these don't.
    public var rowIds: [String] = []
    public var entryCount = 0

    public init() {}
}

/// Folds transcript entries into display rows: file order, tool results
/// attached to their calls, sidecars folded into header state and kept
/// as bookkeeping rows (display decides whether to show them).
public struct SessionAssembler: Sendable {
    public var subagents: SubagentIndex

    public init(subagents: SubagentIndex = SubagentIndex()) {
        self.subagents = subagents
    }

    public func assemble(entries: [TranscriptEntry]) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.entryCount = entries.count
        // tool_use_id → index into snapshot.rows, for attaching results.
        var openCalls: [String: Int] = [:]
        // agentId → row index, for marking forks complete on notification.
        var openForks: [String: Int] = [:]
        // Row index of a `!` command still waiting for its output entry.
        var openConsole: Int?

        for entry in entries {
            switch entry.kind {
            case .aiTitle:
                snapshot.title = entry.aiTitle ?? snapshot.title
                snapshot.rows.append(.bookkeeping(entry))
            case .lastPrompt:
                snapshot.lastPrompt = entry.lastPrompt ?? snapshot.lastPrompt
                snapshot.rows.append(.bookkeeping(entry))
            case .mode:
                snapshot.mode = entry.raw["mode"]?.stringValue ?? snapshot.mode
                snapshot.rows.append(.bookkeeping(entry))
            case .permissionMode:
                snapshot.permissionMode =
                    entry.raw["permissionMode"]?.stringValue ?? snapshot.permissionMode
                snapshot.rows.append(.bookkeeping(entry))
            case .queueOperation, .fileHistorySnapshot, .fileHistoryDelta:
                snapshot.rows.append(.bookkeeping(entry))
            case .summary:
                let text = entry.raw["summary"]?.stringValue ?? "Summary"
                snapshot.rows.append(.info(entry, label: text))
            case .system:
                if let fork = parseForkLaunch(entry) {
                    openForks[fork.agentId] = snapshot.rows.count
                    snapshot.rows.append(.forkLaunch(fork))
                } else {
                    snapshot.rows.append(.info(entry, label: entry.subtype ?? "system"))
                }
            case .attachment:
                markCompletedForks(entry, in: &snapshot, openForks: &openForks)
                let label = entry.raw["attachment"]?["type"]?.stringValue ?? "attachment"
                if label == "total_tokens_reminder" {
                    snapshot.tokensLeft = tokensLeft(of: entry) ?? snapshot.tokensLeft
                }
                snapshot.rows.append(.info(entry, label: label))
            case .user:
                appendUserRows(
                    entry, into: &snapshot, openCalls: &openCalls,
                    openForks: &openForks, openConsole: &openConsole)
            case .assistant:
                appendAssistantRows(entry, into: &snapshot, openCalls: &openCalls)
            case .unknown:
                // Conversation entries always carry a uuid; sidecars never
                // do. An unknown uuid-less type (atis-latch and whatever
                // the harness grows next) is session state, not content.
                if entry.uuid == nil {
                    snapshot.rows.append(.bookkeeping(entry))
                } else {
                    snapshot.rows.append(.unknown(entry))
                }
            }
        }

        if snapshot.title == nil {
            for case .prompt(_, let text) in snapshot.rows {
                snapshot.title = String(text.prefix(60))
                break
            }
        }
        snapshot.rowIds = Self.rowIdentities(for: snapshot.rows)
        return snapshot
    }

    /// Numbers the rows an entry produced, so each gets its own identity.
    /// An assistant message of [text, tool_use, tool_use] is three rows
    /// off one entry; left sharing a key they collide in a SwiftUI
    /// ForEach and two of them never render. Rows for an entry are
    /// emitted together and appends never renumber what came before, so
    /// these stay stable as a live session grows.
    static func rowIdentities(for rows: [SessionRow]) -> [String] {
        var countPerEntry: [String: Int] = [:]
        return rows.map { row in
            let key = row.entryKey
            let ordinal = countPerEntry[key, default: 0]
            countPerEntry[key] = ordinal + 1
            return ordinal == 0 ? key : "\(key).\(ordinal)"
        }
    }

    /// A `local_command` system entry that carries a forked-skill-launch
    /// marker becomes a sub-session row instead of an info row.
    private func parseForkLaunch(_ entry: TranscriptEntry) -> ForkLaunchRowData? {
        guard let content = entry.raw["content"]?.stringValue,
            let markerJSON = LocalCommandMarkup.tagContent("forked-skill-launch", in: content),
            let marker = try? JSONValue(data: Data(markerJSON.utf8)),
            let agentId = marker["agentId"]?.stringValue
        else { return nil }
        return ForkLaunchRowData(
            entry: entry,
            agentId: agentId,
            skillName: marker["skillName"]?.stringValue,
            launchDescription: marker["description"]?.stringValue,
            stdout: LocalCommandMarkup.tagContent("local-command-stdout", in: content)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            subagent: subagents.byAgentId[agentId])
    }

    /// Task notifications name the agent that finished; flip its fork row.
    private func markCompletedForks(
        _ entry: TranscriptEntry,
        in snapshot: inout SessionSnapshot,
        openForks: inout [String: Int]
    ) {
        guard entry.raw["attachment"]?["type"]?.stringValue == "queued_command",
            let prompt = entry.raw["attachment"]?["prompt"]?.stringValue,
            let taskId = LocalCommandMarkup.tagContent("task-id", in: prompt)
        else { return }
        completeFork(taskId: taskId, in: &snapshot, openForks: &openForks)
    }

    private func completeFork(
        taskId: String,
        in snapshot: inout SessionSnapshot,
        openForks: inout [String: Int]
    ) {
        guard let rowIndex = openForks.removeValue(forKey: taskId),
            case .forkLaunch(var fork) = snapshot.rows[rowIndex]
        else { return }
        fork.isComplete = true
        snapshot.rows[rowIndex] = .forkLaunch(fork)
    }

    /// User entries that are really the harness talking — `!` console
    /// exchanges, slash-command output, task notifications — get their own
    /// row shapes instead of masquerading as prompts. Returns false for an
    /// actual prompt.
    private func appendSpecialUserRow(
        _ entry: TranscriptEntry,
        into snapshot: inout SessionSnapshot,
        openForks: inout [String: Int],
        openConsole: inout Int?
    ) -> Bool {
        guard entry.contentBlocks.count == 1,
            case .text(let raw)? = entry.contentBlocks.first
        else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // A notification either leads the entry (session transcripts) or
        // sits behind the harness preamble on a meta entry (subagent
        // ones). Anywhere else the tag is just something someone typed —
        // agent prompts quote it, and those are prompts.
        if entry.isMeta || text.hasPrefix("<task-notification>"),
            let block = LocalCommandMarkup.tagContent("task-notification", in: text)
        {
            let taskId = LocalCommandMarkup.tagContent("task-id", in: block)
            var subagent = taskId.flatMap { subagents.byAgentId[$0] }
            if subagent == nil,
                let toolUseId = LocalCommandMarkup.tagContent("tool-use-id", in: block)
            {
                subagent = subagents.byToolUseId[toolUseId]
            }
            snapshot.rows.append(
                .taskNotification(
                    TaskNotificationRowData(
                        entry: entry,
                        taskId: taskId,
                        status: trimmedTag("status", in: block),
                        summary: trimmedTag("summary", in: block),
                        result: trimmedTag("result", in: block),
                        durationMs: trimmedTag("duration_ms", in: block)
                            .flatMap(Double.init).flatMap(Self.displayableDuration),
                        subagentTokens: trimmedTag("subagent_tokens", in: block).flatMap(Int64.init),
                        toolUses: trimmedTag("tool_uses", in: block).flatMap(Int64.init),
                        subagent: subagent)))
            if let taskId {
                completeFork(taskId: taskId, in: &snapshot, openForks: &openForks)
            }
            return true
        }

        // The console shapes below are only ever the user's own doing, so
        // injected context stays out of them.
        guard !entry.isMeta else { return false }

        if text.hasPrefix("<bash-input>") {
            let command = trimmedTag("bash-input", in: text)
            openConsole = snapshot.rows.count
            snapshot.rows.append(
                .console(ConsoleRowData(entry: entry, command: command ?? text)))
            return true
        }

        if text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") {
            let stdout = consoleText("bash-stdout", in: text)
            let stderr = consoleText("bash-stderr", in: text)
            if let rowIndex = openConsole,
                case .console(var data) = snapshot.rows[rowIndex], data.isPending
            {
                data.stdout = stdout
                data.stderr = stderr
                data.outputEntry = entry
                snapshot.rows[rowIndex] = .console(data)
            } else {
                snapshot.rows.append(
                    .console(
                        ConsoleRowData(
                            entry: entry, command: nil,
                            stdout: stdout, stderr: stderr, outputEntry: entry)))
            }
            openConsole = nil
            return true
        }

        if text.hasPrefix("<local-command-stdout>") {
            snapshot.rows.append(
                .console(
                    ConsoleRowData(
                        entry: entry, command: nil,
                        stdout: consoleText("local-command-stdout", in: text),
                        stderr: consoleText("local-command-stderr", in: text),
                        outputEntry: entry)))
            return true
        }

        return false
    }

    /// "<total_tokens>14945309 tokens left</total_tokens>" → 14945309.
    private func tokensLeft(of entry: TranscriptEntry) -> Int64? {
        guard let text = entry.raw["attachment"]?["text"]?.stringValue,
            let inner = LocalCommandMarkup.tagContent("total_tokens", in: text)
        else { return nil }
        let digits = inner.trimmingCharacters(in: .whitespaces).prefix(while: \.isNumber)
        return Int64(digits)
    }

    /// `Double("inf")`, `Double("nan")` and `Double("1e400")` all succeed,
    /// and a duration the formatter can't render is worse than none —
    /// converting it to Int downstream traps. Keep only what can be shown.
    static func displayableDuration(_ ms: Double) -> Double? {
        ms.isFinite && ms >= 0 && ms < 1e15 ? ms : nil
    }

    private func trimmedTag(_ tag: String, in text: String) -> String? {
        LocalCommandMarkup.tagContent(tag, in: text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tag content readied for display: ANSI escapes stripped, whitespace
    /// trimmed, empty collapsed to nil.
    private func consoleText(_ tag: String, in text: String) -> String? {
        guard let inner = LocalCommandMarkup.tagContent(tag, in: text) else { return nil }
        let stripped = ANSIText.stripped(inner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private func appendUserRows(
        _ entry: TranscriptEntry,
        into snapshot: inout SessionSnapshot,
        openCalls: inout [String: Int],
        openForks: inout [String: Int],
        openConsole: inout Int?
    ) {
        if appendSpecialUserRow(
            entry, into: &snapshot, openForks: &openForks, openConsole: &openConsole)
        {
            return
        }
        var promptPieces: [String] = []
        for block in entry.contentBlocks {
            switch block {
            case .toolResult(let toolUseId, let content, let isError):
                if let rowIndex = openCalls.removeValue(forKey: toolUseId),
                    case .toolCall(var data) = snapshot.rows[rowIndex]
                {
                    data.resultEntry = entry
                    data.resultContent = content
                    data.resultIsError = isError
                    snapshot.rows[rowIndex] = .toolCall(data)
                } else {
                    snapshot.rows.append(.info(entry, label: SessionRow.orphanToolResultLabel))
                }
            case .text(let text):
                promptPieces.append(LocalCommandMarkup.commandPrompt(text) ?? text)
            case .thinking, .toolUse:
                break  // not produced by users
            case .other(let raw):
                if raw["type"]?.stringValue == "image" {
                    promptPieces.append("[image]")
                }
            }
        }
        let text = promptPieces.joined(separator: "\n")
        guard !text.isEmpty else { return }
        if entry.isMeta {
            snapshot.rows.append(.info(entry, label: "injected context"))
        } else {
            snapshot.rows.append(.prompt(entry, text: text))
        }
    }

    private func appendAssistantRows(
        _ entry: TranscriptEntry,
        into snapshot: inout SessionSnapshot,
        openCalls: inout [String: Int]
    ) {
        for block in entry.contentBlocks {
            switch block {
            case .text(let text):
                snapshot.rows.append(.assistantText(entry, text: text))
            case .thinking(let text):
                snapshot.rows.append(.thinking(entry, text: text))
            case .toolUse(let id, let name, let input):
                let data = ToolCallRowData(
                    callEntry: entry,
                    toolUseId: id,
                    name: name,
                    input: input,
                    subagent: subagents.byToolUseId[id])
                openCalls[id] = snapshot.rows.count
                snapshot.rows.append(.toolCall(data))
            case .toolResult:
                break  // not produced by assistants
            case .other:
                snapshot.rows.append(.unknown(entry))
            }
        }
    }
}
