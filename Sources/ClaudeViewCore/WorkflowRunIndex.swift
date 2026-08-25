import Foundation

/// One workflow run under a session: agents spawned by a Workflow
/// script, living in `subagents/workflows/wf_<id>/` beside a journal.
///
/// The journal is the lifecycle truth: a `started` entry when an agent
/// spawns, a terminal entry (`result`, or an error) when it stops. It
/// carries no timestamps, so completion times fall back to the agent
/// transcript's final write.
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
}

public enum WorkflowRunIndex {
    /// All workflow runs under a session's subagents dir, oldest first.
    public static func load(subagentsDir: URL) -> [WorkflowRun] {
        let fm = FileManager.default
        let workflowsDir = subagentsDir.appendingPathComponent("workflows")
        let runDirs = (try? fm.contentsOfDirectory(
            at: workflowsDir, includingPropertiesForKeys: [.creationDateKey])) ?? []

        return runDirs
            .filter { $0.lastPathComponent.hasPrefix("wf_") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (a ?? .distantPast) < (b ?? .distantPast)
            }
            .map { dir in
                load(runDir: dir, subagentsDir: subagentsDir)
            }
    }

    private static func load(runDir: URL, subagentsDir: URL) -> WorkflowRun {
        let runId = runDir.lastPathComponent
        let journalURL = runDir.appendingPathComponent("journal.jsonl")
        let byAgentId = SubagentIndex.load(dir: runDir).byAgentId

        // The journal, wholesale: one line per lifecycle event, a few KB
        // at most even for a long run.
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
            finished: finished)
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
