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

    /// Lines without one of these substrings cannot carry a completion
    /// event — screened on raw bytes before paying for a JSON parse.
    private static let screens = [Data("task-id".utf8), Data("tool_use_id".utf8)]

    public init() {}

    /// Events accumulated for `url`, after folding in newly appended lines.
    /// A shrunken file (rotation, rewrite) resets its state and rescans.
    public func poll(_ url: URL) -> AgentCompletionEvents {
        let tailer: JSONLTailer
        if let existing = tailers[url] {
            tailer = existing
        } else {
            tailer = JSONLTailer(url: url)
            tailers[url] = tailer
        }
        let lines = (try? tailer.poll()) ?? []
        if tailer.didResetOnLastPoll {
            accumulated[url] = AgentCompletionEvents()
        }
        guard !lines.isEmpty else { return current(url) }

        var events = current(url)
        for line in lines {
            guard Self.screens.contains(where: { line.range(of: $0) != nil }),
                let entry = try? TranscriptEntry(line: line, index: 0)
            else { continue }
            fold(entry, into: &events)
        }
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
