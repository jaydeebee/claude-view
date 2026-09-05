import Foundation

/// Agent-stop events accumulated from one spawner transcript: which agents
/// the spawner has heard back from, and when the word arrived.
public struct AgentCompletionEvents: Sendable {
    /// agentId → arrival of its latest task-notification (background
    /// agents, forked skills). Status is irrelevant here: completed,
    /// failed, or killed, the agent has stopped.
    public var byAgentId: [String: Date] = [:]
    /// tool_use_id → arrival of the tool_result answering it. For a Task
    /// call this is the synchronous agent's definitive end.
    public var byToolUseId: [String: Date] = [:]

    public init() {}
}

/// Incrementally scans spawner transcripts for the completion events that
/// idleness heuristics can only guess at. An agent that has gone quiet may
/// be thinking, blocked on a permission prompt, or finished — but once its
/// task-notification or tool_result lands in whoever spawned it, the
/// question is settled.
///
/// State is per-file and reads are incremental (only bytes appended since
/// the last poll), so calling this on every sidebar refresh is cheap after
/// the first pass.
public final class AgentCompletionScanner {
    private var tailers: [URL: JSONLTailer] = [:]
    private var accumulated: [URL: AgentCompletionEvents] = [:]

    /// A notification names its agent here. Rare in a transcript, so a
    /// hit is worth a parse.
    private static let taskIdScreen = Data("task-id".utf8)
    private static let toolUseIdKey = Data("\"tool_use_id\"".utf8)

    public init() {}

    /// The id a `tool_result` line answers, read straight out of the
    /// bytes. Screening on the literal `tool_use_id` instead would match
    /// every tool result in the file — which is where all the megabytes
    /// are — and parsing those is the cost this exists to avoid.
    ///
    /// Whatever JSON allows between the key and its value is stepped over.
    /// The harness writes compact and the old form matched only that, so a
    /// single space after the colon would have silently stopped the
    /// sidebar from ever noticing an agent finish — a format the app does
    /// not own should not be pinned that tightly.
    static func toolUseId(in line: Data) -> String? {
        guard let key = line.range(of: toolUseIdKey) else { return nil }
        var i = key.upperBound
        func skipSpace() {
            while i < line.endIndex, isJSONSpace(line[i]) { i = line.index(after: i) }
        }
        skipSpace()
        guard i < line.endIndex, line[i] == UInt8(ascii: ":") else { return nil }
        i = line.index(after: i)
        skipSpace()
        guard i < line.endIndex, line[i] == UInt8(ascii: "\"") else { return nil }
        i = line.index(after: i)
        guard let end = line[i...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[i..<end], as: UTF8.self)
    }

    private static func isJSONSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    /// Forgets every file outside `urls`.
    ///
    /// The scanner lives as long as the sidebar does, and each file it has
    /// ever polled leaves a tailer and an event table behind. On a machine
    /// with a long history that is a slow leak of things nobody will ask
    /// about again, so each scan says what it still cares about.
    public func retain(_ urls: Set<URL>) {
        tailers = tailers.filter { urls.contains($0.key) }
        accumulated = accumulated.filter { urls.contains($0.key) }
    }

    /// Events accumulated for `url`, after folding in newly appended lines.
    /// A shrunken file (rotation, rewrite) resets its state and rescans.
    ///
    /// `watching` names the tool calls whose results matter — the Task
    /// calls that spawned agents. Every other tool result is skipped
    /// without being parsed. It has no default: an empty set turns tool
    /// result detection off entirely, which is a thing to ask for out
    /// loud, not to fall into by leaving an argument off.
    public func poll(_ url: URL, watching toolUseIds: Set<String>) -> AgentCompletionEvents {
        let tailer: JSONLTailer
        if let existing = tailers[url] {
            tailer = existing
        } else {
            tailer = JSONLTailer(url: url)
            tailers[url] = tailer
        }

        var events = current(url)
        var changed = false
        // Streamed: the scanner screens each line and keeps almost none of
        // them, so there is no reason for the file to arrive as an array.
        try? tailer.poll(onReset: {
            events = AgentCompletionEvents()
            changed = true
        }) { line in
            changed = true
            let carriesEvent =
                line.range(of: Self.taskIdScreen) != nil
                || Self.toolUseId(in: line).map(toolUseIds.contains) == true
            guard carriesEvent, let entry = try? TranscriptEntry(line: line, index: 0)
            else { return }
            fold(entry, into: &events)
        }
        guard changed else { return current(url) }
        accumulated[url] = events
        return events
    }

    /// Events already accumulated for `url`, without touching the file.
    public func current(_ url: URL) -> AgentCompletionEvents {
        accumulated[url] ?? AgentCompletionEvents()
    }

    private func fold(_ entry: TranscriptEntry, into events: inout AgentCompletionEvents) {
        let arrived = entry.timestamp ?? Date()
        switch entry.kind {
        case .user:
            for block in entry.contentBlocks {
                switch block {
                case .text(let raw):
                    // Notifications lead the entry in session transcripts
                    // but sit behind a [SYSTEM NOTIFICATION] preamble in
                    // subagent ones — take the block wherever it is.
                    guard
                        let block = LocalCommandMarkup.tagContent(
                            "task-notification", in: raw)
                    else { continue }
                    if let taskId = LocalCommandMarkup.tagContent("task-id", in: block) {
                        events.byAgentId[taskId] = arrived
                    }
                    if let toolUseId = LocalCommandMarkup.tagContent("tool-use-id", in: block) {
                        events.byToolUseId[toolUseId] = arrived
                    }
                case .toolResult(let toolUseId, _, _):
                    events.byToolUseId[toolUseId] = arrived
                case .thinking, .toolUse, .other:
                    break
                }
            }
        case .attachment:
            // The queued follow-up that relays a background agent's result
            // into the conversation — the same signal the assembler uses to
            // flip fork rows complete.
            guard entry.raw["attachment"]?["type"]?.stringValue == "queued_command",
                let prompt = entry.raw["attachment"]?["prompt"]?.stringValue,
                let taskId = LocalCommandMarkup.tagContent("task-id", in: prompt)
            else { return }
            events.byAgentId[taskId] = arrived
        default:
            break
        }
    }
}
