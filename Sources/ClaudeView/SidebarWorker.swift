import ClaudeViewCore
import Foundation

/// Everything the sidebar draws, gathered in one pass off the main actor.
/// The view's job is then a pure read: no stats, no file reads, no lazily
/// filled caches during body evaluation.
struct SidebarState: Sendable {
    var liveSessions: [RegistrySession] = []
    /// Where each live session's transcript is, by session id. Resolved
    /// here because it can take a directory listing to answer.
    var liveTranscripts: [String: SessionRef] = [:]
    /// History listing, already trimmed to what the sidebar shows.
    var projects: [ProjectListing] = []
    var agentTrees: [String: [ActiveSubagent]] = [:]
    /// Last write of each agent transcript, keyed by the agent's ref id —
    /// what the detail pane's busy indicator asks about.
    var agentActivity: [String: Date] = [:]
    var titles: [URL: String] = [:]
    var usage: [URL: ContextUsage] = [:]
    /// Where each project's sessions actually ran, keyed by project slug.
    /// Read from the transcripts rather than unpicked from the slug.
    var projectPaths: [String: String] = [:]
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
    private var runCache: [URL: (dir: Date, journal: Date, run: WorkflowRun)] = [:]
    private var summaryCache: [URL: (modifiedAt: Date, summary: TranscriptPeek.Summary)] = [:]
    private var cwdCache: [URL: String?] = [:]

    init(paths: ClaudePaths) {
        self.paths = paths
        self.registry = SessionRegistry(paths: paths)
        self.discovery = SessionDiscovery(paths: paths)
    }

    func scan() -> SidebarState {
        var state = SidebarState()
        state.liveSessions = registry.liveSessions()

        let live = Set(state.liveSessions.compactMap(\.sessionId))
        let allProjects = discovery.projects()
        state.projects = allProjects.compactMap { project in
            let rest = project.transcripts
                .filter { !live.contains($0.sessionId) }
                .prefix(Self.historyLimit)
            guard !rest.isEmpty else { return nil }
            return ProjectListing(
                slug: project.slug, url: project.url, transcripts: Array(rest))
        }

        // Live sessions first: their refs are what the agent trees hang off.
        var seen = Set<String>()
        var scanned: Set<URL> = []
        for session in state.liveSessions {
            guard let sessionId = session.sessionId,
                seen.insert(sessionId).inserted,
                let ref = liveRef(for: session, in: allProjects)
            else { continue }
            let url = ref.url
            state.liveTranscripts[sessionId] = ref
            let tree = agentTree(for: ref)
            state.agentTrees[sessionId] = tree
            record(tree, into: &state)
            state.usage[url] = summary(for: url, modifiedAt: modificationDate(of: url)).usage
            scanned.insert(url)
            collectURLs(tree, into: &scanned)
        }
        // Only this pass's files are worth remembering. A session that ends
        // is never polled again, and its tailer and event table would
        // otherwise sit in the scanner for as long as the app runs.
        completionScanner.retain(scanned)

        for project in state.projects {
            for transcript in project.transcripts {
                let summary = summary(
                    for: transcript.url, modifiedAt: transcript.modifiedAt)
                state.titles[transcript.url] = summary.title
                state.usage[transcript.url] = summary.usage
            }
            state.projectPaths[project.slug] = projectPath(of: project)
        }
        // A live session knows its own directory without any reading.
        for session in state.liveSessions {
            guard let cwd = session.cwd else { continue }
            state.projectPaths[ClaudePaths.projectSlug(for: cwd)] = cwd
        }
        return state
    }

    /// Where a live session's transcript is.
    ///
    /// Normally the entry says: cwd and session id give the path without
    /// reading anything. An entry can arrive without a cwd, though, and
    /// one that did vanished from the sidebar completely — no path could
    /// be built for it, so Live dropped it, and History hides whatever
    /// Live is claiming, so History dropped it too. The file is findable
    /// without the cwd: it is the one named after the session.
    private func liveRef(
        for session: RegistrySession, in projects: [ProjectListing]
    ) -> SessionRef? {
        guard let sessionId = session.sessionId else { return nil }
        if let cwd = session.cwd {
            let slug = ClaudePaths.projectSlug(for: cwd)
            return SessionRef(
                projectSlug: slug,
                sessionId: sessionId,
                url: paths.transcriptURL(projectSlug: slug, sessionId: sessionId))
        }
        for project in projects {
            if let match = project.transcripts.first(where: { $0.sessionId == sessionId }) {
                return SessionRef(
                    projectSlug: project.slug, sessionId: sessionId, url: match.url)
            }
        }
        return nil
    }

    /// Every transcript in an agent tree, which is every file the
    /// completion scanner could have been asked about this pass.
    private func collectURLs(_ agents: [ActiveSubagent], into urls: inout Set<URL>) {
        for agent in agents {
            urls.insert(agent.ref.url)
            collectURLs(agent.children, into: &urls)
        }
    }

    private func record(_ agents: [ActiveSubagent], into state: inout SidebarState) {
        for agent in agents {
            state.agentActivity[agent.ref.sessionId] = agent.lastActivity
            record(agent.children, into: &state)
        }
    }

    // MARK: Cached reads

    private func modificationDate(of url: URL) -> Date {
        FileStamp.modified(url)
    }

    /// Every URL on this path comes back out of a cache, so all of these
    /// go through `FileStamp` — see the hazard it documents.
    private func timestamps(of url: URL) -> (created: Date?, modified: Date) {
        let stamp = FileStamp.of(url)
        return (stamp.created, stamp.modified ?? .distantPast)
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

    /// A run is re-read only when its directory or its journal moves. The
    /// journal is not a small file — 235KB for a 32-agent run, every return
    /// value inlined — and a load also re-parses every meta in the run
    /// directory, so doing this per scan cost more than the rest of the
    /// scan put together. Both timestamps are needed: an append moves the
    /// journal without touching the directory around it.
    private func workflowRuns(subagentsDir dir: URL) -> [WorkflowRun] {
        WorkflowRunIndex.runDirectories(subagentsDir: dir).map { runDir in
            let journal = runDir.appendingPathComponent("journal.jsonl")
            let stamps = (modificationDate(of: runDir), modificationDate(of: journal))
            if let cached = runCache[runDir],
                cached.dir == stamps.0, cached.journal == stamps.1
            {
                return cached.run
            }
            let run = WorkflowRunIndex.load(runDir: runDir, subagentsDir: dir)
            runCache[runDir] = (stamps.0, stamps.1, run)
            return run
        }
    }

    /// Where a project's sessions ran. Cached without a timestamp on
    /// purpose: a transcript's opening lines never change, so the answer
    /// for a given file is settled the first time it is read. Newest
    /// transcript first, so an abandoned old one cannot name the project.
    private func projectPath(of project: ProjectListing) -> String? {
        for transcript in project.transcripts {
            if let cached = cwdCache[transcript.url] {
                if let cwd = cached { return cwd }
                continue
            }
            let cwd = TranscriptPeek.quickCwd(url: transcript.url)
            cwdCache[transcript.url] = cwd
            if let cwd { return cwd }
        }
        return nil
    }

    /// Title and context size for one transcript, read once and cached
    /// until the file moves. Both come out of the same tail; asking for
    /// them separately opened and read the file twice for every row.
    private func summary(for url: URL, modifiedAt: Date) -> TranscriptPeek.Summary {
        if let cached = summaryCache[url], cached.modifiedAt == modifiedAt {
            return cached.summary
        }
        let summary = TranscriptPeek.quickSummary(url: url)
        summaryCache[url] = (modifiedAt, summary)
        return summary
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
        let runNodes = workflowRuns(subagentsDir: dir)
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
        let journalAt = modificationDate(of: run.journalURL)
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
                // No result in the journal is only "still working" while
                // the run is; an agent that threw is left there forever.
                completedAt: run.finished.contains(agent.agentId) || run.isComplete
                    ? mtime : nil)
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
            lastActivity: journalAt,
            completedAt: run.isComplete ? journalAt : nil,
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
