import Foundation

/// A subagent spawned by this session, discovered from
/// `<session>/subagents/agent-<id>.meta.json` and joined to its spawning
/// tool call by `toolUseId`.
public struct SubagentRef: Sendable {
    public let toolUseId: String
    public let agentId: String
    public let transcriptURL: URL
    public let agentType: String?
    public let taskDescription: String?

    /// Index every subagent under `dir`, keyed by the spawning tool-use id.
    public static func index(dir: URL) -> [String: SubagentRef] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [String: SubagentRef] = [:]
        for metaURL in files where metaURL.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: metaURL),
                let meta = try? JSONValue(data: data),
                let toolUseId = meta["toolUseId"]?.stringValue
            else { continue }
            let base = metaURL.lastPathComponent.replacingOccurrences(
                of: ".meta.json", with: "")
            result[toolUseId] = SubagentRef(
                toolUseId: toolUseId,
                agentId: base.replacingOccurrences(of: "agent-", with: ""),
                transcriptURL: dir.appendingPathComponent("\(base).jsonl"),
                agentType: meta["agentType"]?.stringValue,
                taskDescription: meta["description"]?.stringValue)
        }
        return result
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

/// One row of the rendered transcript, in file order.
public enum SessionRow: Sendable, Identifiable {
    case prompt(TranscriptEntry, text: String)
    case assistantText(TranscriptEntry, text: String)
    case thinking(TranscriptEntry, text: String)
    case toolCall(ToolCallRowData)
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
    public var subagents: [String: SubagentRef]

    public init(subagents: [String: SubagentRef] = [:]) {
        self.subagents = subagents
    }

    public func assemble(entries: [TranscriptEntry]) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.entryCount = entries.count
        // tool_use_id → index into snapshot.rows, for attaching results.
        var openCalls: [String: Int] = [:]

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
                snapshot.rows.append(.info(entry, label: entry.subtype ?? "system"))
            case .attachment:
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
                promptPieces.append(text)
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
                    subagent: subagents[id])
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
