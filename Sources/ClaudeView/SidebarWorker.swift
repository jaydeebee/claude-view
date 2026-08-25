import ClaudeViewCore
import Foundation

/// Everything the sidebar draws, gathered in one pass off the main actor.
/// The view's job is then a pure read: no stats, no file reads, no lazily
/// filled caches during body evaluation.
struct SidebarState: Sendable {
    var liveSessions: [RegistrySession] = []
    /// History listing, already trimmed to what the sidebar shows.
    var projects: [ProjectListing] = []
    var agentTrees: [String: [ActiveSubagent]] = [:]
    /// Last write of each agent transcript, keyed by the agent's ref id —
    /// what the detail pane's busy indicator asks about.
    var agentActivity: [String: Date] = [:]
    var titles: [URL: String] = [:]
    var usage: [URL: ContextUsage] = [:]
}

/// Owns the scanning state — tailers, indexes, mtime-keyed caches — and
/// runs the scan. An actor, so a burst of FSEvents can't overlap scans.
actor SidebarWorker {
    /// Per project, the sidebar lists this many transcripts; there is no
    /// point peeking at titles nobody will read.
    static let historyLimit = 15

    private let paths: ClaudePaths
    private let registry: SessionRegistry
    private let discovery: SessionDiscovery
    private let completionScanner = AgentCompletionScanner()

    private var indexCache: [URL: (modifiedAt: Date, index: SubagentIndex)] = [:]
    private var titleCache: [URL: (modifiedAt: Date, title: String?)] = [:]
    private var usageCache: [URL: (modifiedAt: Date, usage: ContextUsage?)] = [:]

    init(paths: ClaudePaths) {
        self.paths = paths
        self.registry = SessionRegistry(paths: paths)
        self.discovery = SessionDiscovery(paths: paths)
    }

    func scan() -> SidebarState {
        var state = SidebarState()
        state.liveSessions = registry.liveSessions()

        let live = Set(state.liveSessions.compactMap(\.sessionId))
        state.projects = discovery.projects().compactMap { project in
            let rest = project.transcripts
                .filter { !live.contains($0.sessionId) }
                .prefix(Self.historyLimit)
            guard !rest.isEmpty else { return nil }
            return ProjectListing(
                slug: project.slug, url: project.url, transcripts: Array(rest))
        }

        // Live sessions first: their refs are what the agent trees hang off.
        var seen = Set<String>()
        for session in state.liveSessions {
            guard let sessionId = session.sessionId, let cwd = session.cwd,
                seen.insert(sessionId).inserted
            else { continue }
            let slug = ClaudePaths.projectSlug(for: cwd)
            let url = paths.transcriptURL(projectSlug: slug, sessionId: sessionId)
            let ref = SessionRef(projectSlug: slug, sessionId: sessionId, url: url)
            let tree = agentTree(for: ref)
            state.agentTrees[sessionId] = tree
            record(tree, into: &state)
            state.usage[url] = usage(for: url)
        }

        for project in state.projects {
            for transcript in project.transcripts {
                state.titles[transcript.url] = title(for: transcript)
                state.usage[transcript.url] = usage(for: transcript.url)
            }
        }
        return state
    }

    private func record(_ agents: [ActiveSubagent], into state: inout SidebarState) {
        for agent in agents {
            state.agentActivity[agent.ref.sessionId] = agent.lastActivity
            record(agent.children, into: &state)
        }
    }

    // MARK: Cached reads

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Asked by path, not through the URL. A `URL` memoizes its resource
    /// values, and these come out of the cached subagent index — statting
    /// through them reports whatever was true when the cache was filled,
    /// which freezes every agent's activity while it is still writing.
    private func timestamps(of url: URL) -> (created: Date?, modified: Date) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (
            attributes?[.creationDate] as? Date,
            attributes?[.modificationDate] as? Date ?? .distantPast
        )
    }

    /// Reloaded only when the directory changes — every meta in it is
    /// otherwise re-read and re-parsed on every refresh.
    private func subagentIndex(dir: URL) -> SubagentIndex {
        let mtime = modificationDate(of: dir)
        if let cached = indexCache[dir], cached.modifiedAt == mtime {
            return cached.index
        }
        let index = SubagentIndex.load(dir: dir)
        indexCache[dir] = (mtime, index)
        return index
    }

    private func title(for transcript: TranscriptFile) -> String? {
        if let cached = titleCache[transcript.url],
            cached.modifiedAt == transcript.modifiedAt
        {
            return cached.title
        }
        let title = TranscriptPeek.quickTitle(url: transcript.url)
        titleCache[transcript.url] = (transcript.modifiedAt, title)
        return title
    }

    private func usage(for url: URL) -> ContextUsage? {
        let mtime = modificationDate(of: url)
        if let cached = usageCache[url], cached.modifiedAt == mtime {
            return cached.usage
        }
        let usage = TranscriptPeek.quickUsage(url: url)
        usageCache[url] = (mtime, usage)
        return usage
    }

    // MARK: Agent tree

    /// The complete agent tree for one live session: children nested under
    /// the agent that spawned them, oldest first. Each agent's completion
    /// comes from its spawner's transcript — the session's for depth-1
    /// agents, the parent agent's for those it spawned in turn.
    private func agentTree(for parent: SessionRef) -> [ActiveSubagent] {
        let dir = paths.subagentsDir(
            projectSlug: parent.projectSlug, sessionId: parent.sessionId)
        let index = subagentIndex(dir: dir)
        // Workflow agents live a directory deeper, one subtree per run.
        let runNodes = WorkflowRunIndex.load(subagentsDir: dir)
            .map { workflowNode(for: $0, parent: parent) }
        guard !index.byAgentId.isEmpty else { return runNodes }
        let byParent = Dictionary(
            grouping: index.byAgentId.values, by: { $0.parentAgentId })
        // The only tool results worth reading are the ones answering a
        // Task call that spawned one of these agents.
        let watched = Set(index.byToolUseId.keys)
        var visited = Set<String>()

        func build(
            parentAgentId: String?, events: AgentCompletionEvents, depth: Int
        ) -> [ActiveSubagent] {
            guard depth < 4 else { return [] }
            return (byParent[parentAgentId] ?? [])
                .compactMap { agent -> (SubagentRef, Date?, Date)? in
                    guard visited.insert(agent.agentId).inserted else { return nil }
                    let stamps = timestamps(of: agent.transcriptURL)
                    return (agent, stamps.created, stamps.modified)
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
                                events: completionScanner.poll(
                                    agent.transcriptURL, watching: watched),
                                depth: depth + 1))
                }
        }
        return build(
            parentAgentId: nil,
            events: completionScanner.poll(parent.url, watching: watched),
            depth: 0) + runNodes
    }

    /// A workflow run as one collapsible node: the run's agents are its
    /// children in start order, done-ness straight from the journal — a
    /// serial run shows one spinner and a growing train of checkmarks.
    private func workflowNode(for run: WorkflowRun, parent: SessionRef) -> ActiveSubagent {
        let children = run.agents.enumerated().map { n, agent -> ActiveSubagent in
            let stamps = timestamps(of: agent.transcriptURL)
            let mtime = stamps.modified
            return ActiveSubagent(
                ref: SessionRef(
                    projectSlug: parent.projectSlug,
                    sessionId: "agent-\(agent.agentId)",
                    url: agent.transcriptURL,
                    subagentsDir: run.dir),
                title: agent.name ?? "agent \(n + 1)",
                detail: agent.taskDescription,
                startedAt: stamps.created,
                lastActivity: mtime,
                completedAt: run.finished.contains(agent.agentId) ? mtime : nil)
        }
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
            lastActivity: modificationDate(of: run.journalURL),
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
}
