import Foundation

/// One workflow run under a session: agents spawned by a Workflow
/// script, living in `subagents/workflows/wf_<id>/` beside a journal.
///
/// The journal is the lifecycle truth, as far as it goes: a `started`
/// entry when an agent spawns and a `result` when one returns. Those are
/// the only two shapes it writes — an agent that throws gets a `started`
/// and nothing more — so a missing result means "no answer yet", not
/// "still working". `isComplete` is what tells those apart. The journal
/// carries no timestamps either, so completion times fall back to the
/// agent transcript's final write.
public struct WorkflowRun: Sendable {
    public let runId: String
    /// From the persisted script's filename (`<name>-<runId>.js`).
    public let name: String?
    public let dir: URL
    public let journalURL: URL
    /// Agents in journal start order; agents the journal has not seen
    /// yet (metas without a started entry) trail in filename order.
    public let agents: [SubagentRef]
    /// Agent ids the journal marks terminal.
    public let finished: Set<String>
    /// Whether the run itself has stopped. An agent with no result is
    /// abandoned rather than working once this is true — the journal has
    /// no error entry to say so on the agent's behalf.
    public let isComplete: Bool
}

public enum WorkflowRunIndex {
    /// All workflow runs under a session's subagents dir, oldest first.
    public static func load(subagentsDir: URL) -> [WorkflowRun] {
        runDirectories(subagentsDir: subagentsDir)
            .map { load(runDir: $0, subagentsDir: subagentsDir) }
    }

    /// Just the run directories, oldest first — the cheap half of a load,
    /// so a caller holding a cache can decide what is worth reading.
    public static func runDirectories(subagentsDir: URL) -> [URL] {
        let fm = FileManager.default
        let workflowsDir = subagentsDir.appendingPathComponent("workflows")
        let runDirs = (try? fm.contentsOfDirectory(
            at: workflowsDir, includingPropertiesForKeys: [.creationDateKey])) ?? []

        return runDirs
            .filter { $0.lastPathComponent.hasPrefix("wf_") }
            // Stamped once, then sorted. A comparator that stats is a stat
            // per comparison, not per directory.
            .map { ($0, (try? $0.resourceValues(
                forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// One run. The journal is read whole, and it is not small — a 32-agent
    /// run leaves 235KB here, since every `result` entry carries the
    /// agent's return value inline. Callers on a scan path are expected to
    /// cache this against the journal's timestamp.
    public static func load(runDir: URL, subagentsDir: URL) -> WorkflowRun {
        let runId = runDir.lastPathComponent
        let journalURL = runDir.appendingPathComponent("journal.jsonl")
        let byAgentId = SubagentIndex.load(dir: runDir).byAgentId

        var startOrder: [String] = []
        var finished = Set<String>()
        if let data = try? Data(contentsOf: journalURL) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? JSONValue(data: Data(line)),
                    let agentId = entry["agentId"]?.stringValue
                else { continue }
                if entry["type"]?.stringValue == "started" {
                    if !startOrder.contains(agentId) {
                        startOrder.append(agentId)
                    }
                } else {
                    finished.insert(agentId)
                }
            }
        }

        var agents = startOrder.compactMap { byAgentId[$0] }
        let unseen = byAgentId.keys
            .filter { !startOrder.contains($0) }
            .sorted()
        agents.append(contentsOf: unseen.compactMap { byAgentId[$0] })

        return WorkflowRun(
            runId: runId,
            name: scriptName(runId: runId, subagentsDir: subagentsDir),
            dir: runDir,
            journalURL: journalURL,
            agents: agents,
            finished: finished,
            isComplete: finished.count == agents.count
                || hasStopped(runId: runId, subagentsDir: subagentsDir))
    }

    /// The launcher writes `<session>/workflows/<runId>.json` when a run
    /// stops, carrying the `status` the journal never records. Read only
    /// when the journal leaves an agent unaccounted for: while a run is
    /// live the file is simply absent, and once it exists it is large
    /// (the whole script and every return value are inlined).
    private static func hasStopped(runId: String, subagentsDir: URL) -> Bool {
        let url = subagentsDir.deletingLastPathComponent()
            .appendingPathComponent("workflows/\(runId).json")
        guard let data = try? Data(contentsOf: url),
            let state = try? JSONValue(data: data),
            let status = state["status"]?.stringValue
        else { return false }
        return status != "running"
    }

    /// The launcher persists each run's script as
    /// `<session>/workflows/scripts/<name>-<runId>.js`; the filename is
    /// the only place the human-readable run name lives on disk.
    private static func scriptName(runId: String, subagentsDir: URL) -> String? {
        let scriptsDir = subagentsDir.deletingLastPathComponent()
            .appendingPathComponent("workflows/scripts")
        let scripts = (try? FileManager.default.contentsOfDirectory(
            at: scriptsDir, includingPropertiesForKeys: nil)) ?? []
        let suffix = "-\(runId).js"
        return scripts
            .map(\.lastPathComponent)
            .first { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
    }
}
