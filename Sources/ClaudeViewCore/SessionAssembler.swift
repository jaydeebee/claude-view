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
                parentAgentId: meta["parentAgentId"]?.stringValue)
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

/// One row of the rendered transcript, in file order.
public enum SessionRow: Sendable, Identifiable {
    case prompt(TranscriptEntry, text: String)
    case assistantText(TranscriptEntry, text: String)
    case thinking(TranscriptEntry, text: String)
    case toolCall(ToolCallRowData)
    case forkLaunch(ForkLaunchRowData)
    case info(TranscriptEntry, label: String)
    case unknown(TranscriptEntry)

    public var id: String { "\(entry.id)#\(entry.index)" }

    public var entry: TranscriptEntry {
        switch self {
        case .prompt(let e, _), .assistantText(let e, _), .thinking(let e, _),
            .info(let e, _), .unknown(let e):
            return e
        case .toolCall(let data):
            return data.callEntry
        case .forkLaunch(let data):
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
    public var rows: [SessionRow] = []
    public var entryCount = 0

    public init() {}
}

/// Folds transcript entries into display rows: file order, tool results
/// attached to their calls, sidecars folded into header state.
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

        for entry in entries {
            switch entry.kind {
            case .aiTitle:
                snapshot.title = entry.aiTitle ?? snapshot.title
            case .lastPrompt:
                snapshot.lastPrompt = entry.lastPrompt ?? snapshot.lastPrompt
            case .mode:
                snapshot.mode = entry.raw["mode"]?.stringValue ?? snapshot.mode
            case .permissionMode:
                snapshot.permissionMode =
                    entry.raw["permissionMode"]?.stringValue ?? snapshot.permissionMode
            case .queueOperation, .fileHistorySnapshot, .fileHistoryDelta:
                break  // bookkeeping, not conversation
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
                snapshot.rows.append(.info(entry, label: label))
            case .user:
                appendUserRows(entry, into: &snapshot, openCalls: &openCalls)
            case .assistant:
                appendAssistantRows(entry, into: &snapshot, openCalls: &openCalls)
            case .unknown:
                snapshot.rows.append(.unknown(entry))
            }
        }

        if snapshot.title == nil {
            for case .prompt(_, let text) in snapshot.rows {
                snapshot.title = String(text.prefix(60))
                break
            }
        }
        return snapshot
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
            let taskId = LocalCommandMarkup.tagContent("task-id", in: prompt),
            let rowIndex = openForks.removeValue(forKey: taskId),
            case .forkLaunch(var fork) = snapshot.rows[rowIndex]
        else { return }
        fork.isComplete = true
        snapshot.rows[rowIndex] = .forkLaunch(fork)
    }

    private func appendUserRows(
        _ entry: TranscriptEntry,
        into snapshot: inout SessionSnapshot,
        openCalls: inout [String: Int]
    ) {
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
                    snapshot.rows.append(.info(entry, label: "orphan tool result"))
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
