import ClaudeViewCore
import Foundation
import Observation

/// Identifies one session in the UI, live or historical.
struct SessionRef: Hashable, Identifiable {
    let projectSlug: String
    let sessionId: String
    let url: URL
    /// For subagent transcripts opened directly: the parent session's
    /// subagents dir, so agents-spawned-by-agents still resolve.
    var subagentsDir: URL? = nil

    var id: String { sessionId }
}

/// Root observable state: what sessions exist, which one is selected.
///
/// FSEvents is only a wake-up call — every change handler re-reads the
/// registry and the project listing from disk, so missed or coalesced
/// events cost nothing but latency.
@MainActor
@Observable
final class AppModel {
    let paths: ClaudePaths

    private(set) var liveSessions: [RegistrySession] = []
    private(set) var projects: [ProjectListing] = []
    /// Agent trees per live session id, rebuilt in `refresh()` so the
    /// sidebar's body stays a pure read — no disk IO, no scanner mutation.
    private(set) var agentTrees: [String: [ActiveSubagent]] = [:]
    var selection: SessionRef?
    /// Sidebar filter: hide finished and long-inactive agents when true.
    var agentFilterRunningOnly = false

    private let registry: SessionRegistry
    private let discovery: SessionDiscovery
    private var watcher: FSEventsWatcher?
    /// Incremental per-file scan state — a cache, not view state.
    @ObservationIgnored
    private let completionScanner = AgentCompletionScanner()
    /// Filled lazily from `title(for:)` during List body evaluation — must
    /// stay outside observation, or the write invalidates the sidebar
    /// mid-update and the List paints overlapping rows.
    @ObservationIgnored
    private var titleCache: [String: (modifiedAt: Date, title: String?)] = [:]
    /// Same deal for context sizes — filled during body, so untracked.
    @ObservationIgnored
    private var usageCache: [URL: (modifiedAt: Date, usage: ContextUsage?)] = [:]

    init(paths: ClaudePaths = ClaudePaths()) {
        self.paths = paths
        self.registry = SessionRegistry(paths: paths)
        self.discovery = SessionDiscovery(paths: paths)
    }

    func start() {
        refresh()
        watcher = FSEventsWatcher(
            paths: [paths.projectsDir.path, paths.sessionsDir.path],
            latency: 0.3
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func refresh() {
        liveSessions = registry.liveSessions()
        projects = discovery.projects()
        agentTrees = Dictionary(
            liveRefs.map { ($0.ref.sessionId, buildAgentTree(for: $0.ref)) },
            uniquingKeysWith: { first, _ in first })
    }

    // MARK: Sidebar derivations

    var liveRefs: [(session: RegistrySession, ref: SessionRef)] {
        // A session can briefly own two registry entries (a stale pid file
        // whose pid was recycled, then a resume). The registry lists
        // freshest first; keep that one — duplicate rows corrupt the List.
        var seen = Set<String>()
        return liveSessions.compactMap { session in
            guard let sessionId = session.sessionId,
                let cwd = session.cwd,
                seen.insert(sessionId).inserted
            else { return nil }
            let slug = ClaudePaths.projectSlug(for: cwd)
            return (
                session,
                SessionRef(
                    projectSlug: slug,
                    sessionId: sessionId,
                    url: paths.transcriptURL(projectSlug: slug, sessionId: sessionId))
            )
        }
    }

    private var liveSessionIds: Set<String> {
        Set(liveSessions.compactMap(\.sessionId))
    }

    /// History listing with live sessions removed (they sit in Live above).
    var historyProjects: [(project: ProjectListing, transcripts: [TranscriptFile])] {
        let live = liveSessionIds
        return projects.compactMap { project in
            let rest = project.transcripts.filter { !live.contains($0.sessionId) }
            guard !rest.isEmpty else { return nil }
            return (project, rest)
        }
    }

    /// "-Users-x-src-app" reads poorly; show it relative to $HOME when possible.
    nonisolated static func displayName(forSlug slug: String) -> String {
        let homeSlug = ClaudePaths.projectSlug(
            for: FileManager.default.homeDirectoryForCurrentUser.path)
        if slug.hasPrefix(homeSlug), slug.count > homeSlug.count + 1 {
            return String(slug.dropFirst(homeSlug.count + 1))
        }
        return slug
    }

    /// Sidebar title for a transcript, cached by modification time.
    func title(for transcript: TranscriptFile) -> String? {
        if let cached = titleCache[transcript.sessionId],
            cached.modifiedAt == transcript.modifiedAt
        {
            return cached.title
        }
        let title = TranscriptPeek.quickTitle(url: transcript.url)
        titleCache[transcript.sessionId] = (transcript.modifiedAt, title)
        return title
    }

    /// Context size for a sidebar row, cached by modification time.
    func contextUsage(for url: URL) -> ContextUsage? {
        let mtime =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let cached = usageCache[url], cached.modifiedAt == mtime {
            return cached.usage
        }
        let usage = TranscriptPeek.quickUsage(url: url)
        usageCache[url] = (mtime, usage)
        return usage
    }
}

/// An agent under a live session, surfaced in the sidebar tree. Agents
/// never appear in the session registry, so done-ness comes from the
/// completion event in whoever spawned them; transcript freshness only
/// separates working from waiting while that event is outstanding.
struct ActiveSubagent: Identifiable {
    /// The usual indicators: spinner, orange while unresolved, checkmark
    /// once the spawner has heard the end.
    enum State: Int {
        case completed = 0  // completion event seen, nothing since
        case inactive = 1   // no event, quiet for 10+ minutes
        case idle = 2       // no event, recent activity, not writing now
        case processing = 3  // transcript written in the last 30s
    }

    let ref: SessionRef
    let title: String
    let detail: String?
    let startedAt: Date?
    let lastActivity: Date
    /// When the spawner heard this agent stop; nil while unresolved.
    let completedAt: Date?
    var children: [ActiveSubagent] = []

    /// Transcript writes after the completion event mean the agent was
    /// revived (SendMessage); the old event no longer settles anything.
    private var isSettled: Bool {
        guard let completedAt else { return false }
        return lastActivity <= completedAt.addingTimeInterval(5)
    }

    var state: State {
        if isSettled { return .completed }
        if lastActivity.timeIntervalSinceNow > -30 { return .processing }
        if lastActivity.timeIntervalSinceNow > -600 { return .idle }
        return .inactive
    }

    /// What a collapsed parent shows: its own state or its busiest
    /// descendant's, whichever is more alive — code-review often idles
    /// while its finders work.
    var aggregateState: State {
        children.reduce(state) { max($0, $1.aggregateState) }
    }

    var id: String { ref.sessionId }
}

extension ActiveSubagent.State: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension AppModel {
    /// The complete agent tree for one live session: children nested under
    /// the agent that spawned them, oldest first. Each agent's completion
    /// comes from its spawner's transcript — the session's for depth-1
    /// agents, the parent agent's for those it spawned in turn.
    private func buildAgentTree(for parent: SessionRef) -> [ActiveSubagent] {
        let dir = paths.subagentsDir(
            projectSlug: parent.projectSlug, sessionId: parent.sessionId)
        let index = SubagentIndex.load(dir: dir)
        let runs = WorkflowRunIndex.load(subagentsDir: dir)
        let runNodes = runs.map { workflowNode(for: $0, parent: parent) }
        guard !index.byAgentId.isEmpty else { return runNodes }
        let byParent = Dictionary(
            grouping: index.byAgentId.values, by: { $0.parentAgentId })
        var visited = Set<String>()

        func build(
            parentAgentId: String?, events: AgentCompletionEvents, depth: Int
        ) -> [ActiveSubagent] {
            guard depth < 4 else { return [] }
            return (byParent[parentAgentId] ?? [])
                .compactMap { agent -> (SubagentRef, Date?, Date)? in
                    guard visited.insert(agent.agentId).inserted else { return nil }
                    let values = try? agent.transcriptURL.resourceValues(
                        forKeys: [.creationDateKey, .contentModificationDateKey])
                    return (agent, values?.creationDate,
                            values?.contentModificationDate ?? .distantPast)
                }
                .sorted { ($0.1 ?? .distantPast) < ($1.1 ?? .distantPast) }
                .map { agent, created, mtime in
                    ActiveSubagent(
                        ref: SessionRef(
                            projectSlug: parent.projectSlug,
                            sessionId: "agent-\(agent.agentId)",
                            url: agent.transcriptURL,
                            subagentsDir: dir),
                        title: agent.name ?? agent.agentType ?? "agent",
                        detail: agent.taskDescription,
                        startedAt: created,
                        lastActivity: mtime,
                        completedAt: completedAt(of: agent, mtime: mtime, events: events),
                        children: byParent[agent.agentId] == nil
                            ? []
                            : build(
                                parentAgentId: agent.agentId,
                                events: completionScanner.poll(agent.transcriptURL),
                                depth: depth + 1))
                }
        }
        return build(
            parentAgentId: nil, events: completionScanner.poll(parent.url), depth: 0)
            + runNodes
    }

    /// A workflow run as one collapsible node: the run's agents are its
    /// children in start order, done-ness straight from the journal — a
    /// serial run shows one spinner and a growing train of checkmarks.
    private func workflowNode(for run: WorkflowRun, parent: SessionRef) -> ActiveSubagent {
        let children = run.agents.enumerated().map { n, agent -> ActiveSubagent in
            let values = try? agent.transcriptURL.resourceValues(
                forKeys: [.creationDateKey, .contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            return ActiveSubagent(
                ref: SessionRef(
                    projectSlug: parent.projectSlug,
                    sessionId: "agent-\(agent.agentId)",
                    url: agent.transcriptURL,
                    subagentsDir: run.dir),
                title: agent.name ?? "agent \(n + 1)",
                detail: agent.taskDescription,
                startedAt: values?.creationDate,
                lastActivity: mtime,
                completedAt: run.finished.contains(agent.agentId) ? mtime : nil)
        }
        let journalMtime = (try? run.journalURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ActiveSubagent(
            ref: SessionRef(
                projectSlug: parent.projectSlug,
                sessionId: "wfrun-\(run.runId)",
                url: run.journalURL,
                subagentsDir: run.dir),
            title: run.name ?? run.runId,
            // Short by construction: the sidebar middle-truncates this
            // line, and a chewed "32/45" reads as a plausible wrong count.
            detail: "\(run.finished.count)/\(run.agents.count) agents",
            startedAt: children.first?.startedAt,
            lastActivity: journalMtime ?? .distantPast,
            completedAt: nil,
            children: children)
    }

    /// When the spawner heard this agent stop: a task-notification naming
    /// it, the tool_result answering its Task call, or — for a user-killed
    /// agent that may get neither — the stamp in its meta.
    private func completedAt(
        of agent: SubagentRef, mtime: Date, events: AgentCompletionEvents
    ) -> Date? {
        if let at = events.byAgentId[agent.agentId] { return at }
        if let toolUseId = agent.toolUseId, let at = events.byToolUseId[toolUseId] {
            return at
        }
        return agent.stoppedByUser ? mtime : nil
    }

    /// What the sidebar lists: everything, or — filtered — only agents that
    /// are still unresolved or shelter an unresolved descendant.
    func sidebarAgents(for parent: SessionRef) -> [ActiveSubagent] {
        let tree = agentTrees[parent.sessionId] ?? []
        guard agentFilterRunningOnly else { return tree }
        func prune(_ agents: [ActiveSubagent]) -> [ActiveSubagent] {
            agents.compactMap { agent in
                var kept = agent
                kept.children = prune(agent.children)
                return kept.state >= .idle || !kept.children.isEmpty ? kept : nil
            }
        }
        return prune(tree)
    }

    /// Liveness/busyness for whatever the detail pane is showing. Sessions
    /// answer from the registry; agents answer from parent liveness plus
    /// their own transcript freshness.
    func status(for ref: SessionRef) -> (live: Bool, busy: Bool) {
        if let dir = ref.subagentsDir {
            // The session id is the component above "subagents" — the dir
            // itself may be nested deeper (workflow runs).
            let components = dir.pathComponents
            let parentSessionId = components.lastIndex(of: "subagents")
                .flatMap { $0 > 0 ? components[$0 - 1] : nil }
            let live = liveSessions.contains { $0.sessionId == parentSessionId }
            let mtime = (try? ref.url.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let busy = live && (mtime.map { $0.timeIntervalSinceNow > -20 } ?? false)
            return (live, busy)
        }
        let live = liveRefs.first { $0.ref == ref }
        return (live != nil, live?.session.status == "busy")
    }

    /// FSEvents drives refresh while files change; this slow heartbeat lets
    /// agent states age in the sidebar.
    func startHeartbeat() {
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self.refresh()
            }
        }
    }
}
